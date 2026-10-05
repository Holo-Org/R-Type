// check_layering: enforces ADR 0001 on this POC; scripts/build.sh runs it
// before every build. Odin lets any package import any directory and any
// collection, so the rules are checked here, by reading every package's
// imports with core:odin/parser:
// - a part may only import the parts listed for it below, and the core library;
// - raylib only in the Engine's client part, which must not name it, or any
//   of its own private declarations, in a public declaration;
// - no other vendor package, no collection of our own, no foreign import, and
//   no package outside the listed parts.
//
// usage: check_layering <project root>
package main

import "core:fmt"
import "core:odin/ast"
import "core:odin/parser"
import "core:odin/tokenizer"
import "core:os"
import "core:path/filepath"
import "core:strings"

Part :: struct {
	dir:        string,
	// The parts of this project it may import.
	may_import: []string,
	// May it import vendor:raylib?
	raylib:     bool,
}

PARTS := [?]Part {
	{dir = "engine/headless"},
	{dir = "engine/client", may_import = {"engine/headless"}, raylib = true},
	{dir = "game", may_import = {"engine/headless"}},
	{dir = "server", may_import = {"engine/headless", "game"}},
	{dir = "client", may_import = {"engine/headless", "engine/client", "game"}},
	{dir = "tests/fuzz", may_import = {"engine/headless", "game"}},
	{dir = "scripts/check_layering"},
}

// The vendor packages the Engine's client part may import.
RAYLIB_PACKAGES :: [?]string{"vendor:raylib", "vendor:raylib/rlgl"}

root: string
violations: int

report :: proc(pos: tokenizer.Pos, format: string, args: ..any) {
	relative, _ := filepath.rel(root, pos.file, context.temp_allocator)
	fmt.eprintf("%s(%d:%d) ADR 0001: ", relative, pos.line, pos.column)
	fmt.eprintfln(format, ..args)
	violations += 1
}

find_part :: proc(dir: string) -> (part: Part, found: bool) {
	for p in PARTS {
		if p.dir == dir {
			return p, true
		}
	}
	return
}

is_raylib :: proc(path: string) -> bool {
	for package_path in RAYLIB_PACKAGES {
		if path == package_path {
			return true
		}
	}
	return false
}

// Checks one import of a file of `part`: `path` is the import path, without
// quotes, and `file_dir` the importing file's directory.
check_import :: proc(part: Part, at: tokenizer.Pos, path, file_dir: string) {
	if colon := strings.index_byte(path, ':'); colon >= 0 {
		switch collection := path[:colon]; collection {
		case "core", "base":
		case "vendor":
			if !is_raylib(path) {
				report(at, "%s may not import %q: no vendor package but raylib is version-managed in this project", part.dir, path)
			} else if !part.raylib {
				report(at, "%s may not import %q: raylib stays behind the Engine's client part", part.dir, path)
			}
		case:
			report(at, "%s may not import %q: the collection %q is not part of this project's layout", part.dir, path, collection)
		}
		return
	}
	target_path, _ := filepath.join({file_dir, path}, context.temp_allocator)
	target, err := filepath.rel(root, target_path, context.temp_allocator)
	if err != nil || strings.has_prefix(target, "..") {
		report(at, "%s may not import %q: it lies outside the project", part.dir, path)
		return
	}
	for allowed in part.may_import {
		if target == allowed {
			return
		}
	}
	switch {
	case strings.has_prefix(part.dir, "engine/") && target == "game":
		report(at, "%s may not import %q: the Engine knows nothing about the Game", part.dir, path)
	case target == "engine/client":
		report(at, "%s may not import %q: only the Client program draws, the Server and the Game stay headless", part.dir, path)
	case:
		report(at, "%s may not import %q (%s): it is not one of the parts it may use", part.dir, path, target)
	}
}

// ---- The public API of the Engine's client part ----------------------------

// What the AST walk looks for, in one file, and what it found.
raylib_names: [dynamic]string
private_names: map[string]bool
exposed: Maybe(tokenizer.Pos)
exposed_what: string

is_private :: proc(attributes: []^ast.Attribute) -> bool {
	for attribute in attributes {
		for elem in attribute.elems {
			#partial switch e in elem.derived {
			case ^ast.Ident:
				if e.name == "private" {
					return true
				}
			case ^ast.Field_Value:
				if ident, ok := e.field.derived.(^ast.Ident); ok && ident.name == "private" {
					return true
				}
			}
		}
	}
	return false
}

is_private_file :: proc(file: ^ast.File) -> bool {
	return parser.parse_file_tags(file^, context.temp_allocator).private != .Public
}

// Notes the first raylib selector, or the first private name.
find_exposure :: proc(node: ^ast.Node) -> bool {
	if node == nil || exposed != nil {
		return false
	}
	#partial switch n in node.derived {
	case ^ast.Selector_Expr:
		if package_name, ok := n.expr.derived.(^ast.Ident); ok {
			for name in raylib_names {
				if package_name.name == name {
					exposed, exposed_what = node.pos, fmt.tprintf("raylib's %s.%s", name, n.field.name)
					return false
				}
			}
		}
		return false // the field in `a.field` is not one of our names
	case ^ast.Ident:
		if private_names[n.name] {
			exposed, exposed_what = node.pos, fmt.tprintf("the private %s", n.name)
		}
	}
	return true
}

// Public declarations: their types, signatures and values, but not the
// bodies of their procedures, may mention neither raylib nor a private name.
check_public_declarations :: proc(stmts: []^ast.Stmt) {
	for stmt in stmts {
		#partial switch s in stmt.derived {
		case ^ast.When_Stmt:
			check_public_declarations({s.body})
			if s.else_stmt != nil {
				check_public_declarations({s.else_stmt})
			}
		case ^ast.Block_Stmt:
			check_public_declarations(s.stmts)
		case ^ast.Value_Decl:
			if is_private(s.attributes[:]) {
				continue
			}
			exposed = nil
			if s.type != nil {
				ast.inspect(s.type, find_exposure)
			}
			for value in s.values {
				if procedure, is_proc := value.derived.(^ast.Proc_Lit); is_proc {
					ast.inspect(procedure.type, find_exposure)
				} else {
					ast.inspect(value, find_exposure)
				}
			}
			if at, found := exposed.?; found {
				name := "declaration"
				if ident, ok := s.names[0].derived.(^ast.Ident); ok {
					name = ident.name
				}
				report(at, "engine/client's public %s exposes %s: raylib stays behind the Engine's client part", name, exposed_what)
			}
		}
	}
}

collect_private_names :: proc(pkg: ^ast.Package) {
	clear(&private_names)
	for _, file in pkg.files {
		file_private := is_private_file(file)
		for stmt in file.decls {
			decl, ok := stmt.derived.(^ast.Value_Decl)
			if !ok || !(file_private || is_private(decl.attributes[:])) {
				continue
			}
			for name in decl.names {
				if ident, is_ident := name.derived.(^ast.Ident); is_ident {
					private_names[ident.name] = true
				}
			}
		}
	}
}

// ---- Walking the project ------------------------------------------------------

check_package :: proc(dir: string) {
	relative, _ := filepath.rel(root, dir, context.temp_allocator)
	pkg, ok := parser.parse_package_from_path(dir)
	if !ok {
		fmt.eprintfln("%s: cannot parse the package", relative)
		violations += 1
		return
	}
	part, known := find_part(relative)
	if !known {
		for _, file in pkg.files {
			report(file.pkg_decl.pos, "%s is not one of the parts of this project's layout", relative)
			break
		}
		return
	}
	if part.raylib {
		collect_private_names(pkg)
	}
	for _, file in pkg.files {
		clear(&raylib_names)
		for decl in file.imports {
			path := strings.trim(decl.relpath.text, "\"`")
			check_import(part, decl.pos, path, filepath.dir(file.fullpath))
			if is_raylib(path) {
				append(&raylib_names, decl.name.text if decl.name.text != "" else filepath.base(path))
			}
		}
		for stmt in file.decls {
			if foreign_import, is_foreign := stmt.derived.(^ast.Foreign_Import_Decl); is_foreign {
				report(foreign_import.pos, "%s may not import a foreign library: libraries come from the vendor collection", part.dir)
			}
		}
		if part.raylib && !is_private_file(file) {
			check_public_declarations(file.decls[:])
		}
	}
}

main :: proc() {
	if len(os.args) != 2 {
		fmt.eprintln("usage: check_layering <project root>")
		os.exit(2)
	}
	absolute, err := os.get_absolute_path(os.args[1], context.allocator)
	if err != nil {
		fmt.eprintfln("check_layering: cannot find %s", os.args[1])
		os.exit(2)
	}
	root = absolute

	// Every directory that holds Odin files, except the build output.
	dirs: map[string]bool
	walker := os.walker_create(root)
	defer os.walker_destroy(&walker)
	for info in os.walker_walk(&walker) {
		if info.type == .Directory && (info.name == "out" || strings.has_prefix(info.name, ".")) {
			os.walker_skip_dir(&walker)
		} else if info.type == .Regular && strings.has_suffix(info.name, ".odin") {
			dirs[strings.clone(filepath.dir(info.fullpath))] = true
		}
	}
	for dir in dirs {
		check_package(dir)
	}
	if violations > 0 {
		fmt.eprintfln("check_layering: %d violation(s) of ADR 0001", violations)
		os.exit(1)
	}
}
