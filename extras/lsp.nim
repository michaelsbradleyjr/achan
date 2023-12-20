{.warning: "This module is not intended for compilation!".}

# this is a support module for nimlangserver so that a minimal spawning of
# nimsuggest processes can service all modules in achan; see
# ./project-mapping.el and ../.vscode/settings.json

import
  achan,
  examples/achan1,
  tests/test_all

{.warning[UnusedImport]: off.}
