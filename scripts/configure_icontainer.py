"""Wrapper that delegates to configure_sicontainer.py for SIContainer repository."""
from pathlib import Path
import runpy

runpy.run_path(str(Path(__file__).resolve().parent / "configure_sicontainer.py"), run_name="__main__")
