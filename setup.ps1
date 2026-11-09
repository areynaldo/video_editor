# One-time setup after "git clone": get the Dear ImGui bindings and apply one small fix.
git submodule update --init
git -C deps/odin-imgui apply --check ../../patches/odin-imgui-opengl3.patch 2>$null
if ($LASTEXITCODE -eq 0) {
	git -C deps/odin-imgui apply ../../patches/odin-imgui-opengl3.patch
	"Fix applied."
} else {
	"The fix is already applied."
}
