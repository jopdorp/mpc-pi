"""Import the hub's Router from a hyphenated filename.

maschine-hub.py cannot be imported normally because of the hyphen, and
renaming it would change the command users type. This shim loads it by
path so the routing logic is testable.
"""
import importlib.util
import os

_here = os.path.dirname(os.path.abspath(__file__))
_path = os.path.join(_here, "..", "scripts", "maschine", "maschine-hub.py")
_spec = importlib.util.spec_from_file_location("maschine_hub", _path)
_mod = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_mod)

Router = _mod.Router
