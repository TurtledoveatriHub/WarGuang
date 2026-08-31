"""Compatibility launcher for the GodotIQ MCP server."""

from __future__ import annotations

import inspect
import typing

from mcp.server.fastmcp.exceptions import InvalidSignature
from mcp.server.fastmcp.server import Context
from mcp.server.fastmcp.tools import base as tool_base
from mcp.server.fastmcp.utilities import func_metadata as func_metadata_module

## Preserve the original FastMCP behavior for everything except annotation repair.
_original_get_typed_annotation = func_metadata_module._get_typed_annotation


## Patch FastMCP tool registration to tolerate future annotations.
def _patched_from_function(cls, fn, name=None, description=None, context_kwarg=None, annotations=None):
	func_name = name or fn.__name__
	if func_name == "<lambda>":
		raise ValueError("You must provide a name for lambda functions")
	func_doc = description or fn.__doc__ or ""
	is_async = tool_base._is_async_callable(fn)

	if context_kwarg is None:
		sig = inspect.signature(fn)
		globalns = dict(getattr(fn, "__globals__", {}))
		globalns.setdefault("Context", Context)
		try:
			hints = typing.get_type_hints(fn, globalns=globalns, include_extras=True)
		except Exception:
			hints = {}
		for param_name, param in sig.parameters.items():
			annotation = hints.get(param_name, param.annotation)
			if typing.get_origin(annotation) is not None:
				continue
			try:
				if issubclass(annotation, Context):
					context_kwarg = param_name
					break
			except TypeError:
				continue

	globalns = getattr(fn, "__globals__", None)
	if isinstance(globalns, dict):
		globalns.setdefault("Context", Context)

	func_arg_metadata = tool_base.func_metadata(
		fn,
		skip_names=[context_kwarg] if context_kwarg is not None else [],
	)
	parameters = func_arg_metadata.arg_model.model_json_schema()

	return cls(
		fn=fn,
		name=func_name,
		description=func_doc,
		parameters=parameters,
		fn_metadata=func_arg_metadata,
		is_async=is_async,
		context_kwarg=context_kwarg,
		annotations=annotations,
	)


## Patch annotation evaluation used by FastMCP signatures.
def _patched_get_typed_annotation(annotation, globalns):
	patched_globalns = dict(globalns or {})
	patched_globalns.setdefault("Context", Context)
	if annotation == "Context":
		return Context
	try:
		return _original_get_typed_annotation(annotation, patched_globalns)
	except InvalidSignature:
		if str(annotation) == "ForwardRef('Context')":
			return Context
		raise


tool_base.Tool.from_function = classmethod(_patched_from_function)
func_metadata_module._get_typed_annotation = _patched_get_typed_annotation

import godotiq.server as server


if __name__ == "__main__":
	server.main()