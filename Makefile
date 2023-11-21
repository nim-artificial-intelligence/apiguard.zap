.phony: build run debugbuild debug bundle deps

deps:
	zon2nix build.zig.zon > deps.nix

build: deps
	zig build -Doptimize=ReleaseSafe

run: build 
	./zig-out/bin/apiguard 2>&1 | tee -a prod.log

debugbuild: deps
	zig build 

debugrun: debugbuild
	./zig-out/bin/apiguard

