# Sushi Language for VS Code

This extension adds syntax highlighting and basic editor configuration for Sushi source files.

## Package and install

From this directory:

```bash
./package-vsix.sh
```

Then install the generated `.vsix` in VS Code:

1. Open Extensions.
2. Select the `...` menu.
3. Select `Install from VSIX...`.
4. Choose the generated `sushi-language-*.vsix` file.
5. Reload VS Code.

## Development

Open this directory in VS Code and press `F5` to launch an Extension Development Host.

## Features

- Associates `.sushi` files with the Sushi language.
- Highlights comments, strings, template interpolation, numbers, booleans, keyword symbols, block keywords, definitions, built-ins, operators, list/table delimiters, and `\\` block shorthand.
- Configures semicolon comments, bracket pairs, auto-closing pairs, folding markers, and indentation rules.
