-- R-Type language POC, C++ edition: see README.md to build and run, REPORT.md for the findings.
set_project("r-type-poc-cpp")
set_version("0.1.0")
set_xmakever("3.1.1")

set_languages("c++23")
set_warnings("allextra")
add_rules("mode.release", "mode.debug")
-- xmake f -m asan: optimized, with debug info, AddressSanitizer and UndefinedBehaviorSanitizer.
if is_mode("asan") then
    set_symbols("debug")
    set_optimize("faster")
    set_policy("build.sanitizer.address", true)
    set_policy("build.sanitizer.undefined", true)
end

if is_plat("mingw") then
    -- Self-contained .exe files: no libstdc++, libgcc or thread-runtime DLL to ship.
    add_ldflags("-static")
    -- libstdc++ keeps std::print's Windows console support in a separate library.
    add_syslinks("stdc++exp")
end

-- Pin every package version and the xmake-repo commit in xmake-requires.lock.
set_policy("package.requires_lock", true)
add_requires("asio 1.36.0")
add_requires("raylib 6.0")

-- ADR 0001, enforced by the build: Engine code never depends on Game code,
-- and the Server never reaches raylib, not even through a dependency.
rule("rtype.engine")
    on_config(function (target)
        for _, dep in ipairs(target:orderdeps()) do
            if not dep:rule("rtype.engine") then
                raise("Engine target %s must not depend on %s", target:name(), dep:name())
            end
        end
    end)

rule("rtype.headless")
    on_config(function (target)
        if target:pkg("raylib") then
            raise("%s must stay headless, but uses raylib", target:name())
        end
        for _, dep in ipairs(target:orderdeps()) do
            if not dep:rule("rtype.headless") then
                raise("%s must stay headless, but depends on %s", target:name(), dep:name())
            end
        end
    end)

-- Engine, headless part: bytes, UDP transport, fixed-step clock.
target("engine-headless")
    set_kind("static")
    add_rules("rtype.engine", "rtype.headless")
    add_files("engine/headless/*.cppm", {public = true})
    add_files("engine/headless/*.cpp")
    add_packages("asio")
    if is_plat("windows", "mingw") then
        add_defines("_WIN32_WINNT=0x0A00")
    end

-- Engine, client part: window, drawing, input, sound, over raylib. raylib stays
-- private: dependents link it, but cannot include it.
target("engine-client")
    set_kind("static")
    add_rules("rtype.engine")
    add_files("engine/client/*.cppm", {public = true})
    add_files("engine/client/*.cpp")
    add_packages("raylib")

-- Game: messages and Match rules.
target("game")
    set_kind("static")
    add_rules("rtype.headless")
    add_deps("engine-headless")
    add_files("game/*.cppm", {public = true})
    add_files("game/*.cpp")

target("r-type_server")
    set_kind("binary")
    add_rules("rtype.headless")
    add_deps("game", "engine-headless")
    add_files("server/*.cpp")

target("r-type_client")
    set_kind("binary")
    add_deps("game", "engine-headless", "engine-client")
    -- The sprite sheet is compiled into the program, so the .exe runs on its own.
    add_rules("utils.bin2c", {extensions = ".gif", nozeroend = true})
    add_files("client/*.cppm", "client/*.cpp", "client/*.c", "assets/r-typesheet42.gif")

target("protocol_fuzz")
    set_kind("binary")
    set_group("tests")
    add_rules("rtype.headless")
    add_deps("game", "engine-headless")
    add_files("tests/protocol_fuzz.cpp")
    add_tests("fuzz", {realtime_output = true})
