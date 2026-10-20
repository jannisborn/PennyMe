"""Check environment loading before the backend imports Slack."""

import ast
import os
from pathlib import Path
import subprocess
import sys
import tempfile


def test_startup_loads_dotenv_before_slack_imports():
    """Exercise the app's first import with a fake Waitress entry point."""
    app_path = Path(__file__).resolve().parents[1] / "app.py"
    first_statement = ast.parse(app_path.read_text()).body[0]
    startup_import = ast.unparse(first_statement)
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        (root / ".project-root").touch()
        (root / ".env").write_text("SLACK_APP_TOKEN=startup-test-token\n")
        entrypoint = root / ".venv" / "bin" / "waitress-serve"
        entrypoint.parent.mkdir(parents=True)
        entrypoint.write_text(
            f"{startup_import}\n"
            "import os\n"
            "assert os.environ['SLACK_APP_TOKEN'] == 'startup-test-token'\n"
        )
        environment = dict(os.environ)
        environment.pop("SLACK_APP_TOKEN", None)
        environment.pop("PYTHON_DOTENV_DISABLED", None)
        subprocess.run(
            [sys.executable, str(entrypoint)],
            env=environment,
            check=True,
            capture_output=True,
        )
