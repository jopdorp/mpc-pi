"""Import daw-ctl's Daw class from an extensionless filename.

daw-ctl is a command users type, so it has no .py and cannot be
imported normally. This shim loads it by path, which is what lets the
interaction tests drive the real state reducer rather than a copy of it
written for the tests - a copy would pass while the shipped one broke.
"""
import importlib.machinery
import importlib.util
import os

_here = os.path.dirname(os.path.abspath(__file__))
_path = os.path.join(_here, "..", "scripts", "daw", "daw-ctl")
# An explicit SourceFileLoader is required: spec_from_file_location
# infers the loader from the file extension, and daw-ctl has none, so
# the spec comes back with loader=None and module_from_spec dies with a
# bare AttributeError that says nothing about the cause.
_spec = importlib.util.spec_from_file_location(
    "daw_ctl_main", _path,
    loader=importlib.machinery.SourceFileLoader("daw_ctl_main", _path))
_mod = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_mod)

Daw = _mod.Daw
STRIPS = _mod.STRIPS
LANES = _mod.LANES
