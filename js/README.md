This is an experimental project to compile semgrep-core to Javascript
using js_of_ocaml to compile the OCaml code and emscripten and WASM to
compile the C code generated by tree-sitter.

After 'make core', you should get a 110MB Javascript file under
\_build/default/js/semgrep-core.js

You can then load this file in your browser and test it with:
TODO

You can also load this file in nodejs and test it with:
TODO