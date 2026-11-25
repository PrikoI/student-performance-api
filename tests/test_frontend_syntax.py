import re
import shutil
import subprocess
import unittest
from pathlib import Path

class FrontendSyntaxTests(unittest.TestCase):
    @unittest.skipUnless(shutil.which("node"), "Node.js is required for frontend syntax validation")
    def test_embedded_javascript_parses(self):
        html=Path("app/app.html").read_text(encoding="utf-8")
        scripts=re.findall(r"<script>([\s\S]*?)</script>",html)
        self.assertTrue(scripts)
        for index,script in enumerate(scripts):
            result=subprocess.run(["node","--check","-"],input=script,text=True,encoding="utf-8",capture_output=True)
            self.assertEqual(result.returncode,0,f"script {index}: {result.stderr}")

if __name__=="__main__":
    unittest.main()
