# claude-talk-mcp — コマンドラインビルド
#
#   make build            … MCPサーバー + アプリを dist/ にビルド（Xcode不要）
#   make zip              … dist/ の .app を zip 化（配布用）
#   make release VERSION=v0.1.0
#                         … ビルド→zip→GitHub Release 作成（gh 必須）
#   make clean            … 生成物を削除
#
# アプリはアドホック署名（Signature=adhoc）でビルドする。マイク用 entitlement は
# 埋め込まれるので、配布先でも初回に許可ダイアログが出る（未署名配布のため
# Gatekeeper で「開発元未確認」になる点は README のトラブルシュート参照）。

SCHEME  = claude-talk-mcp
PROJECT = claude-talk-mcp.xcodeproj
CONFIG  = Release
DERIVED = build
DIST    = dist
APP     = $(DIST)/claude-talk-mcp.app
MCPBIN  = $(DIST)/claude-talk-mcp-server
VERSION ?= dev

.PHONY: all build mcp app zip release clean

all: build

build: mcp app

## MCP サーバー（Swift Package）
mcp:
	cd MCPServer && swift build -c release
	@mkdir -p $(DIST)
	cp MCPServer/.build/release/claude-talk-mcp-server $(MCPBIN)
	@echo "==> MCP server: $(MCPBIN)"

## 音声アプリ（xcodebuild / アドホック署名）
app:
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration $(CONFIG) \
	  -derivedDataPath $(DERIVED) \
	  CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="" \
	  CODE_SIGNING_REQUIRED=YES CODE_SIGNING_ALLOWED=YES \
	  build
	@mkdir -p $(DIST)
	rm -rf $(APP)
	cp -R $(DERIVED)/Build/Products/$(CONFIG)/claude-talk-mcp.app $(APP)
	@echo "==> App: $(APP)"

## 配布用 zip（.app はディレクトリなので ditto で固める）
zip: build
	cd $(DIST) && ditto -c -k --keepParent claude-talk-mcp.app claude-talk-mcp-app-macos.zip
	@echo "==> Zipped: $(DIST)/claude-talk-mcp-app-macos.zip"

## GitHub Release を作成してビルド済みをアップロード（要 gh 認証）
release: zip
	@test "$(VERSION)" != "dev" || { echo "VERSION=v0.1.0 のように指定してください"; exit 1; }
	gh release create $(VERSION) \
	  $(DIST)/claude-talk-mcp-app-macos.zip \
	  $(MCPBIN) \
	  --title "$(VERSION)" \
	  --notes "macOS 用ビルド。app はアドホック署名（初回起動は右クリック→開く）。MCP サーバーバイナリ同梱。ASR は README の setup.sh を参照。"
	@echo "==> Released $(VERSION)"

clean:
	rm -rf $(DERIVED) $(DIST) MCPServer/.build
	@echo "==> cleaned"
