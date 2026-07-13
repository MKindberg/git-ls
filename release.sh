set -e
RELEASE_DIR="release-$(git describe --tags)"
rm -rf "${RELEASE_DIR}"
mkdir "${RELEASE_DIR}"
zig build --release=small
cd zig-out
tar -czf ../"${RELEASE_DIR}"/git-ls_x86_64_linux.tar.gz bin/git-ls
zig build --release=small -Dtarget=aarch64-macos
tar -czf ../"${RELEASE_DIR}"/git-ls_aarch64_macos.tar.gz bin/git-ls
cd ..
sed "s/VERSION/$(git describe --tags)/" editors/nvim/registry.json > "${RELEASE_DIR}"/registry.json
cp editors/nvim/plugin.lua "${RELEASE_DIR}"/plugin.lua
cd "${RELEASE_DIR}"
zip -jr registry.json.zip registry.json
sha256sum registry.json registry.json.zip > checksums.txt
rm registry.json

