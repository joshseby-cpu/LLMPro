"""diffusion_server.py — long-lived, OpenAI-compatible HTTP server for DiffusionGemma.

This is the Code-tab server for *text-diffusion* models. mlx-lm's own
``python -m mlx_lm server`` cannot host DiffusionGemma (a masked/block-diffusion
LM with no mlx-lm model class), so the coding agent talks to this tiny stdlib
server instead. The model is loaded ONCE at boot and reused across every turn —
that's the whole reason this exists rather than re-running ``diffusion_generate.py``
per message (a ~30 s reload each turn would make agentic use unusable).

The inference code is NOT a pip dependency: it is the vendored ``optiq.vlm``
DiffusionGemma subset that lives next to this file in ``diffusion_vendor/``
(see ``diffusion_vendor/VENDORED.md`` for provenance/license). This server adds
that directory to ``sys.path`` and imports ``optiq.vlm.diffusion_gemma``; it
needs only mlx / mlx-lm / transformers / numpy — all in the LLMPro runtime venv,
no torch, no Flask.

Wire contract (the subset of the OpenAI chat API ``OpenAIChatClient.swift`` speaks):

  GET  /health               -> {"status":"ok","model":<arg>}
  GET  /v1/models            -> {"object":"list","data":[{"id":<arg>,"object":"model",...}]}
  POST /v1/chat/completions  request:  {model, messages[], tools?, temperature,
                                        max_tokens, stream, chat_template_kwargs?}
    non-stream response: {id, object:"chat.completion", created, model,
                          choices:[{index, message:{role,content,tool_calls?},
                                    finish_reason}], usage:{...}}
    stream (SSE):        Content-Type: text/event-stream; lines prefixed "data: ",
                          each frame {id, object:"chat.completion.chunk",
                          choices:[{index, delta:{role?|content?|tool_calls?},
                                    finish_reason}]}; terminated by "data: [DONE]".

Tool-call translation (the load-bearing bit):
  DiffusionGemma's chat template renders the request ``tools`` into its own tool
  grammar and is trained to EMIT calls as
      <|tool_call>call:NAME{key:value,...}<tool_call|>
  with string args quoted ``<|"|>value<|"|>``. After generation we scan the full
  text for those blocks and convert each to an OpenAI ``tool_calls`` entry
  (arguments as a JSON *string*), stripping the block from the visible content.
  This is **fail-open**: any block that won't parse is left as-is and, if NO
  block parses, the raw text is returned as plain ``content`` with no
  ``tool_calls`` (the Swift agent has its own text-fallback parser).

  Streaming translates on the COMPLETE buffer, not token-by-token: partial Gemma
  tool syntax mid-stream would corrupt the parse, and the Swift client only acts
  on stream completion anyway. So content deltas stream live, but any tool calls
  are emitted as a single final delta with finish_reason "tool_calls".

Threading: ``ThreadingHTTPServer`` accepts concurrent requests, but ALL MLX work
runs on a single dedicated worker thread. This is required, not just for
serialization (the model isn't reentrant): MLX's generation stream is a
*thread-local* object created at import time, so a decode launched on an
arbitrary HTTP worker thread fails with "no Stream(gpu, 0) in current thread".
Requests submit a job to the worker via a queue; the worker owns the model and
the stream for the whole process lifetime. Non-stream callers block on a result
event; stream callers drain segments off a per-request queue the worker fills.

CLI:
    python diffusion_server.py --model <ABS-PATH-or-repo-id> --port <int>
        [--host 127.0.0.1]

On a successful load it prints exactly one line ``LLMPRO_DIFFUSION_SERVER_READY
port=<port>`` to stdout (flushed) and then serves forever. On load failure it
prints the error to stderr and exits non-zero. This server is launched under
``mlx_run.py`` by the app (which pins MLX memory), so it does NOT self-pin.
"""

from __future__ import annotations

import argparse
import json
import os
import queue
import sys
import threading
import time
import traceback
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# Make the vendored optiq.vlm.diffusion_gemma subtree importable. The package is
# a sibling ``diffusion_vendor/`` dir; everything inside resolves via relative
# imports once that dir is on sys.path.
_VENDOR_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "diffusion_vendor")
if _VENDOR_DIR not in sys.path:
    sys.path.insert(0, _VENDOR_DIR)

# Populated once in main() after the model loads. The handler reads these.
_MODEL = None
_TOKENIZER = None
_MODEL_ARG = ""  # the --model value, echoed back as the model id

# All MLX work runs on this single worker thread (see module docstring). HTTP
# threads put a 0-arg job callable here; the worker runs them strictly in order.
_JOB_QUEUE: "queue.Queue" = queue.Queue()
# Sentinel a stream worker puts on its output queue to signal end-of-stream.
_STREAM_END = object()

DEFAULT_MAX_TOKENS = 512
DEFAULT_SAMPLER = "confidence-threshold"
EMPTY_RETRY_ATTEMPTS = 3  # the diffusion canvas occasionally collapses to empty


# ---------------------------------------------------------------------------
# Tool-call translation: DiffusionGemma's <|tool_call> grammar -> OpenAI shape
# ---------------------------------------------------------------------------

# The model emits string args as <|"|>...<|"|> and may leak thinking channels
# (<|channel>thought ... <channel|>). These are the only specials we need to
# reason about for translation; everything else passes through verbatim.
_GEMMA_QUOTE = '<|"|>'


def _strip_thinking_channels(text: str) -> str:
    """Drop ``<|channel>...<channel|>`` thinking spans from model output.

    The chat template forces a ``<|channel>thought\\n<channel|>`` opener when
    thinking is disabled, and a thinking model emits full thought spans. Neither
    belongs in the user-visible ``content`` — mirror the template's
    ``strip_thinking`` macro (split on the close tag, drop text after an open
    tag within each part).
    """
    if "<|channel>" not in text:
        return text
    out = []
    for part in text.split("<channel|>"):
        if "<|channel>" in part:
            out.append(part.split("<|channel>")[0])
        else:
            out.append(part)
    return "".join(out)


# Residual tool-protocol special tokens the model leaks around a tool call (e.g.
# the template appends ``<|tool_response>`` after a call when no result follows).
# These must not appear in the user-visible ``content``. Mirrors the strip set in
# the Swift side's AgentTools.sanitizeToolBlock.
_RESIDUAL_SPECIALS = (
    "<|tool_response>", "<tool_response|>",
    "<|tool_call>", "<tool_call|>",
    "<|tool>", "<tool|>",
    "<|turn>", "<turn|>",
    "<end_of_turn>", "<start_of_turn>",
    "<|think|>", "<eos>", "<bos>",
)


def _clean_visible(text: str) -> str:
    """Strip thinking channels + residual tool-protocol specials, then trim."""
    text = _strip_thinking_channels(text)
    for tok in _RESIDUAL_SPECIALS:
        text = text.replace(tok, "")
    return text.strip()


def _find_tool_call_blocks(text: str) -> list[tuple[int, int, str, str]]:
    """Locate every ``<|tool_call>call:NAME{...}<tool_call|>`` block.

    Returns ``(start, end, name, body)`` tuples where ``[start:end)`` spans the
    whole block (so it can be excised from the visible content) and ``body`` is
    the raw text between the outermost braces. Brace matching is quote-aware:
    the Gemma quote token ``<|"|>`` can wrap arbitrary text (including ``{`` /
    ``}``), so we don't count braces inside a quoted string.
    """
    blocks: list[tuple[int, int, str, str]] = []
    open_tag = "<|tool_call>call:"
    close_tag = "<tool_call|>"
    i = 0
    n = len(text)
    while True:
        start = text.find(open_tag, i)
        if start == -1:
            break
        name_start = start + len(open_tag)
        brace = text.find("{", name_start)
        if brace == -1:
            break
        name = text[name_start:brace].strip()
        # Walk to the matching close brace, skipping anything inside <|"|>…<|"|>.
        depth = 0
        j = brace
        body_end = -1
        in_quote = False
        while j < n:
            if text.startswith(_GEMMA_QUOTE, j):
                in_quote = not in_quote
                j += len(_GEMMA_QUOTE)
                continue
            ch = text[j]
            if not in_quote:
                if ch == "{":
                    depth += 1
                elif ch == "}":
                    depth -= 1
                    if depth == 0:
                        body_end = j
                        break
            j += 1
        if body_end == -1:
            # Unterminated block; stop scanning (rest is partial/garbage).
            break
        body = text[brace + 1:body_end]
        # The block ends at the close tag if present, else right after the brace
        # (some emits drop the trailing tag); excise up to whichever we find.
        after = text.find(close_tag, body_end)
        if after != -1 and after - body_end <= len(close_tag) + 2:
            end = after + len(close_tag)
        else:
            end = body_end + 1
        blocks.append((start, end, name, body))
        i = end
    return blocks


def _parse_braced_object(s: str) -> dict:
    """Parse a full braced object in Gemma's brace-list syntax into a dict.

    Example input::

        {path:<|"|>README.md<|"|>,recursive:true,depth:2}

    Grammar (recursive): an object is ``key:value`` pairs separated by commas;
    a value is a quoted string (``<|"|>…<|"|>``), ``true`` / ``false`` /
    ``null``, a number, a nested ``{…}`` object, or a ``[…]`` list. Keys in
    call bodies are bare (the template renders them with ``escape_keys=False``),
    but we also accept quoted keys defensively. Raises ``ValueError`` on
    anything it can't parse so the caller can fail-open and skip the block.
    """
    pos = 0
    length = len(s)

    def skip_ws() -> None:
        nonlocal pos
        while pos < length and s[pos] in " \t\r\n":
            pos += 1

    def parse_quoted() -> str:
        nonlocal pos
        # at a <|"|>; consume to the next <|"|>
        pos += len(_GEMMA_QUOTE)
        end = s.find(_GEMMA_QUOTE, pos)
        if end == -1:
            raise ValueError("unterminated quoted string")
        val = s[pos:end]
        pos = end + len(_GEMMA_QUOTE)
        return val

    def parse_key() -> str:
        nonlocal pos
        skip_ws()
        if s.startswith(_GEMMA_QUOTE, pos):
            return parse_quoted()
        # bare key: read up to ':' (keys never contain ':' or structural chars)
        start = pos
        while pos < length and s[pos] not in ":,{}[]":
            pos += 1
        key = s[start:pos].strip()
        if not key:
            raise ValueError("empty key")
        return key

    def parse_value():
        nonlocal pos
        skip_ws()
        if pos >= length:
            raise ValueError("unexpected end of value")
        if s.startswith(_GEMMA_QUOTE, pos):
            return parse_quoted()
        ch = s[pos]
        if ch == "{":
            return parse_object()
        if ch == "[":
            return parse_array()
        # scalar token: read up to a structural delimiter
        start = pos
        while pos < length and s[pos] not in ",}]":
            pos += 1
        token = s[start:pos].strip()
        return _coerce_scalar(token)

    def parse_object() -> dict:
        nonlocal pos
        obj: dict = {}
        skip_ws()
        if pos < length and s[pos] == "{":
            pos += 1
        skip_ws()
        if pos < length and s[pos] == "}":
            pos += 1
            return obj
        while True:
            key = parse_key()
            skip_ws()
            if pos >= length or s[pos] != ":":
                raise ValueError(f"expected ':' after key {key!r}")
            pos += 1
            obj[key] = parse_value()
            skip_ws()
            if pos < length and s[pos] == ",":
                pos += 1
                skip_ws()
                continue
            if pos < length and s[pos] == "}":
                pos += 1
            break
        return obj

    def parse_array() -> list:
        nonlocal pos
        arr: list = []
        if pos < length and s[pos] == "[":
            pos += 1
        skip_ws()
        if pos < length and s[pos] == "]":
            pos += 1
            return arr
        while True:
            arr.append(parse_value())
            skip_ws()
            if pos < length and s[pos] == ",":
                pos += 1
                skip_ws()
                continue
            if pos < length and s[pos] == "]":
                pos += 1
            break
        return arr

    skip_ws()
    if pos >= length or s[pos] != "{":
        raise ValueError("expected '{' at start of object")
    return parse_object()


def _coerce_scalar(token: str):
    """Turn a bare scalar token into bool / None / int / float / str."""
    low = token.lower()
    if low == "true":
        return True
    if low == "false":
        return False
    if low in ("null", "none"):
        return None
    try:
        return int(token)
    except ValueError:
        pass
    try:
        return float(token)
    except ValueError:
        pass
    return token


def _parse_object_body(body: str) -> dict:
    """Parse a bare ``key:value,key:value`` body (the inside of a tool-call's
    outer braces) into a dict, by wrapping it and reusing the braced-object
    parser."""
    return _parse_braced_object("{" + body + "}")


def translate_tool_calls(raw_text: str) -> tuple[str, list[dict]]:
    """Convert Gemma tool-call blocks in ``raw_text`` to OpenAI tool calls.

    Returns ``(visible_content, tool_calls)`` where ``visible_content`` has the
    translated blocks removed (and thinking channels stripped) and each tool
    call is ``{"id","type":"function","function":{"name","arguments"}}`` with
    ``arguments`` a JSON *string*. Fail-open: a block that won't parse is left
    in the visible content and contributes no tool call.
    """
    blocks = _find_tool_call_blocks(raw_text)
    if not blocks:
        return _clean_visible(raw_text), []

    tool_calls: list[dict] = []
    kept_spans: list[tuple[int, int]] = []  # (start, end) of blocks we DID translate
    n = 0
    for start, end, name, body in blocks:
        if not name:
            continue
        try:
            args_obj = _parse_object_body(body)
        except Exception:
            # Unparseable — leave it in the visible text, emit no call.
            continue
        if not isinstance(args_obj, dict):
            continue
        tool_calls.append(
            {
                "id": f"call_{n}",
                "type": "function",
                "function": {"name": name, "arguments": json.dumps(args_obj, ensure_ascii=False)},
            }
        )
        kept_spans.append((start, end))
        n += 1

    if not tool_calls:
        # Nothing parsed — fail open to plain text (Swift has a text fallback).
        return _clean_visible(raw_text), []

    # Remove only the spans we successfully translated, back-to-front.
    visible = raw_text
    for start, end in sorted(kept_spans, reverse=True):
        visible = visible[:start] + visible[end:]
    return _clean_visible(visible), tool_calls


# ---------------------------------------------------------------------------
# Generation
# ---------------------------------------------------------------------------


def _build_prompt_ids(messages: list, tools, chat_template_kwargs: dict | None):
    """Apply the chat template and return a list of token ids.

    Mirrors ``diffusion_generate.py``: template to a string (carrying BOS), then
    encode WITHOUT extra specials and pass the id list so the decoder doesn't add
    a second BOS. ``tools`` (the OpenAI ``tools`` array) is forwarded into the
    template, which renders the model's tool grammar.
    """
    kwargs = dict(chat_template_kwargs or {})
    templated = _TOKENIZER.apply_chat_template(
        messages,
        tools=(tools or None),
        add_generation_prompt=True,
        tokenize=False,
        **kwargs,
    )
    return _TOKENIZER.encode(templated, add_special_tokens=False)


def _diffusion_worker_loop() -> None:
    """The single MLX-owning thread: run queued jobs strictly in order forever.

    Each job is a 0-arg callable that does its own result delivery (a non-stream
    job sets an event; a stream job fills an output queue). Jobs must not raise
    past here — they capture their own exceptions — so the worker never dies.
    """
    while True:
        job = _JOB_QUEUE.get()
        try:
            job()
        except Exception as exc:  # defensive: a job should handle its own errors
            Log_err(f"worker job crashed: {exc}\n{traceback.format_exc()[:800]}")
        finally:
            _JOB_QUEUE.task_done()


def _usage_from(last) -> dict:
    if last is None:
        return {"prompt_tokens": 0, "completion_tokens": 0, "total_tokens": 0}
    pt = int(getattr(last, "prompt_tokens", 0) or 0)
    ct = int(getattr(last, "generation_tokens", 0) or 0)
    return {"prompt_tokens": pt, "completion_tokens": ct, "total_tokens": pt + ct}


def _generate(ids, *, max_tokens: int, temperature: float) -> tuple[str, dict]:
    """Run a full (non-stream) diffusion decode on the worker thread.

    Submits the decode as a job and blocks the calling HTTP thread until it
    finishes. Retries a blank decode (the canvas can collapse to empty noise)
    up to ``EMPTY_RETRY_ATTEMPTS`` times, matching the vendored ``generate()``.
    """
    done = threading.Event()
    box: dict = {"text": "", "usage": _usage_from(None), "error": None}

    def job() -> None:
        try:
            import optiq.vlm.diffusion_gemma as dg

            text = ""
            last = None
            for _attempt in range(EMPTY_RETRY_ATTEMPTS):
                text = ""
                for r in dg.stream_generate(
                    _MODEL, _TOKENIZER, ids,
                    max_tokens=max_tokens, temperature=temperature, sampler=DEFAULT_SAMPLER,
                ):
                    last = r
                    if getattr(r, "is_draft", False):
                        continue
                    if r.text:
                        text += r.text
                if text.strip():
                    break
            box["text"] = text
            box["usage"] = _usage_from(last)
        except Exception as exc:  # surfaced to the HTTP thread as a 500
            box["error"] = exc
        finally:
            done.set()

    _JOB_QUEUE.put(job)
    done.wait()
    if box["error"] is not None:
        raise box["error"]
    return box["text"], box["usage"]


def _generate_stream(ids, *, max_tokens: int, temperature: float):
    """Generator yielding ``(segment, usage_or_None)`` from a worker-thread decode.

    The decode runs on the MLX worker; revealed non-draft segments are pushed
    onto a thread-safe queue this generator drains, so content streams live to
    the HTTP thread. Yields ``(segment, None)`` per segment, then a final
    ``(None, usage)`` so the caller can translate the COMPLETE buffer for tool
    calls. Empty-decode retry: a blank stream is re-run. A worker exception is
    re-raised here so the SSE handler can emit a terminal error frame.
    """
    out: "queue.Queue" = queue.Queue()

    def job() -> None:
        try:
            import optiq.vlm.diffusion_gemma as dg

            last = None
            produced_any = False
            for _attempt in range(EMPTY_RETRY_ATTEMPTS):
                produced_any = False
                for r in dg.stream_generate(
                    _MODEL, _TOKENIZER, ids,
                    max_tokens=max_tokens, temperature=temperature, sampler=DEFAULT_SAMPLER,
                ):
                    last = r
                    if getattr(r, "is_draft", False):
                        continue
                    if r.text:
                        produced_any = True
                        out.put(("segment", r.text))
                if produced_any:
                    break
                # else: blank decode — retry the whole stream.
            out.put(("usage", _usage_from(last)))
        except Exception as exc:
            out.put(("error", exc))
        finally:
            out.put((_STREAM_END, None))

    _JOB_QUEUE.put(job)
    while True:
        kind, value = out.get()
        if kind is _STREAM_END:
            break
        if kind == "segment":
            yield value, None
        elif kind == "usage":
            yield None, value
        elif kind == "error":
            raise value


# ---------------------------------------------------------------------------
# HTTP handler
# ---------------------------------------------------------------------------


def _completion_id() -> str:
    return "chatcmpl-" + uuid.uuid4().hex[:24]


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    # Quiet the default stderr access log (the app reads our stdout, not this).
    def log_message(self, fmt: str, *args) -> None:  # noqa: A002 - stdlib signature
        pass

    # -- small response helpers --

    def _send_json(self, code: int, obj: dict) -> None:
        body = json.dumps(obj, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _send_sse_headers(self) -> None:
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "keep-alive")
        # Chunked: we don't know the body length up front.
        self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()

    def _sse_send(self, obj: dict) -> None:
        """Write one ``data: {json}\\n\\n`` SSE frame as an HTTP chunk + flush."""
        payload = "data: " + json.dumps(obj, ensure_ascii=False) + "\n\n"
        self._write_chunk(payload.encode("utf-8"))

    def _sse_done(self) -> None:
        self._write_chunk(b"data: [DONE]\n\n")
        self._write_chunk(b"")  # terminating zero-length chunk

    def _write_chunk(self, data: bytes) -> None:
        """Write one HTTP/1.1 chunked-transfer chunk and flush immediately."""
        self.wfile.write(f"{len(data):X}\r\n".encode("ascii"))
        if data:
            self.wfile.write(data)
        self.wfile.write(b"\r\n")
        self.wfile.flush()

    # -- routing --

    def do_GET(self) -> None:  # noqa: N802 - stdlib signature
        path = self.path.split("?", 1)[0]
        if path == "/health":
            self._send_json(200, {"status": "ok", "model": _MODEL_ARG})
        elif path == "/v1/models":
            self._send_json(
                200,
                {
                    "object": "list",
                    "data": [
                        {"id": _MODEL_ARG, "object": "model", "created": 0, "owned_by": "local"}
                    ],
                },
            )
        else:
            self._send_json(404, {"error": {"message": f"Not found: {path}"}})

    def do_POST(self) -> None:  # noqa: N802 - stdlib signature
        path = self.path.split("?", 1)[0]
        if path != "/v1/chat/completions":
            self._send_json(404, {"error": {"message": f"Not found: {path}"}})
            return

        # Parse the request body.
        try:
            length = int(self.headers.get("Content-Length", "0"))
            raw = self.rfile.read(length) if length else b""
            req = json.loads(raw.decode("utf-8")) if raw else {}
            if not isinstance(req, dict):
                raise ValueError("body must be a JSON object")
            messages = req.get("messages")
            if not isinstance(messages, list) or not messages:
                raise ValueError("'messages' must be a non-empty array")
            tools = req.get("tools")
            if tools is not None and not isinstance(tools, list):
                raise ValueError("'tools' must be an array")
            temperature = float(req.get("temperature") or 0.0)
            max_tokens = int(req.get("max_tokens") or DEFAULT_MAX_TOKENS)
            stream = bool(req.get("stream", False))
            chat_template_kwargs = req.get("chat_template_kwargs")
            if chat_template_kwargs is not None and not isinstance(chat_template_kwargs, dict):
                raise ValueError("'chat_template_kwargs' must be an object")
        except Exception as exc:  # malformed request -> 400
            self._send_json(400, {"error": {"message": f"Bad request: {exc}"}})
            return

        # Build the prompt (template errors are the client's fault -> 400).
        try:
            ids = _build_prompt_ids(messages, tools, chat_template_kwargs)
        except Exception as exc:
            Log_err(f"prompt build failed: {exc}")
            self._send_json(400, {"error": {"message": f"Could not build prompt: {exc}"}})
            return

        if stream:
            self._handle_stream(ids, max_tokens=max_tokens, temperature=temperature)
        else:
            self._handle_nonstream(ids, max_tokens=max_tokens, temperature=temperature)

    # -- handlers --

    def _handle_nonstream(self, ids, *, max_tokens: int, temperature: float) -> None:
        try:
            raw_text, usage = _generate(ids, max_tokens=max_tokens, temperature=temperature)
        except Exception as exc:
            Log_err(f"generation failed: {exc}\n{traceback.format_exc()[:800]}")
            self._send_json(500, {"error": {"message": f"Generation failed: {exc}"}})
            return

        content, tool_calls = translate_tool_calls(raw_text)
        message: dict = {"role": "assistant"}
        # OpenAI: content may be null on a pure tool-call turn.
        message["content"] = content if content else (None if tool_calls else "")
        if tool_calls:
            message["tool_calls"] = tool_calls
        self._send_json(
            200,
            {
                "id": _completion_id(),
                "object": "chat.completion",
                "created": int(time.time()),
                "model": _MODEL_ARG,
                "choices": [
                    {
                        "index": 0,
                        "message": message,
                        "finish_reason": "tool_calls" if tool_calls else "stop",
                    }
                ],
                "usage": usage,
            },
        )

    def _handle_stream(self, ids, *, max_tokens: int, temperature: float) -> None:
        cid = _completion_id()
        created = int(time.time())

        def frame(delta: dict, finish_reason=None) -> dict:
            return {
                "id": cid,
                "object": "chat.completion.chunk",
                "created": created,
                "model": _MODEL_ARG,
                "choices": [{"index": 0, "delta": delta, "finish_reason": finish_reason}],
            }

        self._send_sse_headers()
        try:
            # Opening frame: announce the assistant role.
            self._sse_send(frame({"role": "assistant"}))

            buffer = ""
            usage = {"prompt_tokens": 0, "completion_tokens": 0, "total_tokens": 0}
            for segment, seg_usage in _generate_stream(
                ids, max_tokens=max_tokens, temperature=temperature
            ):
                if seg_usage is not None:
                    usage = seg_usage
                    break
                if segment:
                    buffer += segment
                    # Stream content live. We don't strip Gemma syntax mid-stream
                    # (translation runs on the complete buffer at the end); a tool
                    # call's raw text would briefly appear, but the Swift client
                    # only acts on completion, where we send the clean version.
                    self._sse_send(frame({"content": segment}))

            content, tool_calls = translate_tool_calls(buffer)
            if tool_calls:
                # Emit tool calls as one final delta; do NOT also re-send as
                # content (the live content stream already showed the raw text,
                # and the client builds its turn from these tool_calls).
                tc_delta = [
                    {
                        "index": i,
                        "id": tc["id"],
                        "type": "function",
                        "function": tc["function"],
                    }
                    for i, tc in enumerate(tool_calls)
                ]
                self._sse_send(frame({"tool_calls": tc_delta}, finish_reason="tool_calls"))
            else:
                self._sse_send(frame({}, finish_reason="stop"))
            self._sse_done()
        except Exception as exc:
            Log_err(f"stream generation failed: {exc}\n{traceback.format_exc()[:800]}")
            # Mid-stream we've already sent 200 + headers, so we can't switch to a
            # 500. Send a final error-bearing frame + [DONE] so the client unblocks.
            try:
                self._sse_send(frame({"content": f"\n[server error: {exc}]"}, finish_reason="stop"))
                self._sse_done()
            except Exception:
                pass


def Log_err(msg: str) -> None:  # noqa: N802 - tiny stderr logger, not a class
    """Log to stderr (the app captures the server's stderr for diagnostics)."""
    sys.stderr.write(f"[diffusion_server] {msg}\n")
    sys.stderr.flush()


# ---------------------------------------------------------------------------
# Boot
# ---------------------------------------------------------------------------


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="OpenAI-compatible HTTP server for DiffusionGemma on MLX.")
    p.add_argument("--model", required=True, help="Local model dir (abs path) or HF repo id.")
    p.add_argument("--host", default="127.0.0.1")
    p.add_argument("--port", required=True, type=int)
    return p.parse_args()


def resolve_model(model: str) -> str:
    """Expand ``~`` for local paths; pass repo ids through untouched."""
    expanded = os.path.expanduser(model)
    return os.path.abspath(expanded) if os.path.isdir(expanded) else model


def _worker_main(model_path: str, ready: threading.Event, box: dict) -> None:
    """Worker-thread entry point: own all MLX state, then serve jobs forever.

    The vendored decode uses a module-global ``generation_stream`` created by
    ``mx.new_thread_local_stream`` at *import time*, bound to the importing
    thread. So this thread — not main — must do BOTH the import AND the load,
    or every later decode fails with "no Stream(gpu, 0) in current thread".
    Signals ``ready`` once the model is loaded (or an error is recorded in
    ``box``), then runs :func:`_diffusion_worker_loop`.
    """
    global _MODEL, _TOKENIZER
    try:
        import optiq.vlm.diffusion_gemma as dg
    except Exception as exc:
        box["error"] = f"vendored diffusion import failed: {exc}\n{traceback.format_exc()[:800]}"
        ready.set()
        return
    try:
        _MODEL, _TOKENIZER = dg.load(model_path)
    except Exception as exc:
        box["error"] = f"model load failed: {exc}\n{traceback.format_exc()[:800]}"
        ready.set()
        return
    ready.set()
    _diffusion_worker_loop()


def main() -> int:
    global _MODEL_ARG
    args = parse_args()
    _MODEL_ARG = args.model
    model_path = resolve_model(args.model)

    # Load the model + own MLX on a single dedicated worker thread (see
    # _worker_main); block here until it's ready or has failed.
    ready = threading.Event()
    box: dict = {"error": None}
    worker = threading.Thread(
        target=_worker_main, args=(model_path, ready, box), name="mlx-worker", daemon=True
    )
    worker.start()
    ready.wait()
    if box["error"] is not None:
        Log_err(box["error"])
        return 3

    httpd = ThreadingHTTPServer((args.host, args.port), Handler)
    # The READY sentinel the app waits for on stdout. MUST be the only stdout line.
    sys.stdout.write(f"LLMPRO_DIFFUSION_SERVER_READY port={args.port}\n")
    sys.stdout.flush()
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        httpd.server_close()
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        raise SystemExit(130)
    except Exception as exc:
        Log_err(f"{type(exc).__name__}: {exc}\n{traceback.format_exc()[:800]}")
        raise SystemExit(1)
