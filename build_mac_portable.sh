#!/usr/bin/env bash
# =============================================================================
# pyvideotrans macOS 绿色版（便携版）构建脚本
#
# 用法（在 macOS 上运行，本机或 GitHub Actions macos runner 均可）:
#   bash build_mac_portable.sh [arm64|x86_64]      # 默认 arm64
#
# 可选环境变量:
#   UV_DEFAULT_INDEX   pip 包镜像源（中国大陆本机构建时建议设为国内镜像）
#
# 产物: build-mac-portable/sp-mac-portable-<arch>.zip
#   解压后双击「启动.command」即可运行，目标 Mac 无需任何 Python 环境。
#
# 包内结构:
#   sp-mac-portable/
#   ├── 启动.command            # 双击启动
#   ├── 使用说明-Mac.txt
#   ├── sp.py + videotrans/ ... # 完整源码
#   ├── runtime/                # 独立 Python 3.10 + 全部依赖（darwin 为 torch CPU）
#   ├── models/                 # SenseVoiceSmall + 中文标点 + 降噪小模型（离线）
#   ├── ffmpeg/                 # mac 版 ffmpeg / ffprobe 静态二进制
#   └── logs/ tmp/ output/      # 运行时自动生成
# =============================================================================
set -euo pipefail

ARCH="${1:-arm64}"
case "$ARCH" in
  arm64)  FFMPEG_SRC="osxexperts" ;;  # Apple Silicon: osxexperts.net 静态构建
  x86_64) FFMPEG_SRC="evermeet"   ;;  # Intel: evermeet.cx 静态构建
  *) echo "[x] 不支持的架构: $ARCH（可选 arm64 | x86_64）"; exit 1 ;;
esac

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$REPO_ROOT/build-mac-portable"
PKG="$BUILD_DIR/sp-mac-portable"
TOOLS_BIN="$BUILD_DIR/tools/bin"
mkdir -p "$BUILD_DIR" "$PKG"

log() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
die() { printf '\033[1;31m[x] %s\033[0m\n' "$*" >&2; exit 1; }

[ "$(uname -s)" = "Darwin" ] || die "必须在 macOS 上运行（Windows 无法构建 Mac 程序）"
[ "$(uname -m)" = "$ARCH" ] || die "当前机器架构 $(uname -m) 与目标架构 $ARCH 不一致"

# ---------------------------------------------------------------------------
# 1. 安装 uv（用于安装 Python 运行时与依赖）
# ---------------------------------------------------------------------------
log "安装 uv 构建工具"
if [ ! -x "$TOOLS_BIN/uv" ]; then
  UV_UNMANAGED_INSTALL="$TOOLS_BIN" curl -LsSf https://astral.sh/uv/install.sh | sh
fi
export PATH="$TOOLS_BIN:$PATH"

# ---------------------------------------------------------------------------
# 2. 内置独立 Python（python-build-standalone 发行版，可重定位、目标机零依赖）
# ---------------------------------------------------------------------------
log "安装内置 Python 3.10 到包内 runtime/"
rm -rf "$PKG/runtime"
export UV_PYTHON_INSTALL_DIR="$PKG/runtime"
uv python install 3.10
PYBIN="$(find "$PKG/runtime" -type f -name 'python3.10' -path '*/bin/*' | head -n 1)"
[ -x "$PYBIN" ] || die "未找到内置 python3.10"
"$PYBIN" --version

# ---------------------------------------------------------------------------
# 3. 从 uv.lock 导出依赖清单并安装进内置 Python
#    darwin 平台按 pyproject.toml [tool.uv.sources] 解析 torch CPU 版
# ---------------------------------------------------------------------------
log "导出并安装 Python 依赖（约 10-20 分钟）"
uv lock
uv export --frozen --no-hashes --no-dev --no-emit-project -o "$BUILD_DIR/requirements.txt"
uv pip install --break-system-packages --python "$PYBIN" --index-strategy unsafe-best-match \
  -r "$BUILD_DIR/requirements.txt"

# pysoundfile 0.9(旧占位包) 与 soundfile 0.13 文件互相覆盖，强制重装正确版本
log "重装 soundfile 修复 libsndfile 冲突"
uv pip install --break-system-packages --reinstall --python "$PYBIN" "soundfile==0.13.1"

# ---------------------------------------------------------------------------
# 4. 复制源码到包目录
# ---------------------------------------------------------------------------
log "复制源码到包目录"
rsync -a \
  --exclude '.git' --exclude '.gitignore' --exclude '.venv' \
  --exclude 'build' --exclude 'dist' --exclude 'build-mac-portable' \
  --exclude 'models' --exclude 'ffmpeg' --exclude 'output' --exclude 'logs' \
  --exclude 'tmp' --exclude 'tests' --exclude 'audio_cpp' --exclude 'whisper-cpp' \
  --exclude '.github' --exclude '__pycache__' --exclude '*.pyc' \
  "$REPO_ROOT/" "$PKG/"

# ---------------------------------------------------------------------------
# 5. 下载内置模型（保证 SenseVoiceSmall 语音转录离线可用）
# ---------------------------------------------------------------------------
log "下载模型 SenseVoiceSmall + 中文标点模型（约 1.3GB）"
rm -rf "$PKG/models"
"$PYBIN" - <<PYEOF
from modelscope import snapshot_download
snapshot_download('iic/SenseVoiceSmall', local_dir='$PKG/models/SenseVoiceSmall')
snapshot_download('iic/punc_ct-transformer_zh-cn-common-vocab272727-pytorch',
                  local_dir='$PKG/models/punc_ct-transformer_zh-cn-common-vocab272727-pytorch')
print('models done')
PYEOF
[ -f "$PKG/models/SenseVoiceSmall/model.pt" ] || die "SenseVoiceSmall/model.pt 下载失败"

log "下载降噪小模型 dpdfnet2.onnx"
mkdir -p "$PKG/models/onnx"
curl -fL --retry 3 \
  "https://hf-mirror.com/mortimerme/repocollect/resolve/main/onnx/dpdfnet2.onnx?download=true" \
  -o "$PKG/models/onnx/dpdfnet2.onnx"

# ---------------------------------------------------------------------------
# 6. 下载 ffmpeg / ffprobe 静态二进制并 ad-hoc 签名
# ---------------------------------------------------------------------------
log "下载 ffmpeg / ffprobe ($ARCH)"
FFTMP="$BUILD_DIR/ffmpeg-tmp"
rm -rf "$FFTMP"; mkdir -p "$FFTMP" "$PKG/ffmpeg"
if [ "$FFMPEG_SRC" = "osxexperts" ]; then
  curl -fL --retry 3 "https://www.osxexperts.net/ffmpeg9arm.zip"  -o "$FFTMP/ffmpeg.zip"
  curl -fL --retry 3 "https://www.osxexperts.net/ffprobe9arm.zip" -o "$FFTMP/ffprobe.zip"
else
  curl -fL --retry 3 "https://evermeet.cx/ffmpeg/get/ffmpeg/zip"  -o "$FFTMP/ffmpeg.zip"
  curl -fL --retry 3 "https://evermeet.cx/ffmpeg/get/ffprobe/zip" -o "$FFTMP/ffprobe.zip"
fi

for name in ffmpeg ffprobe; do
  ditto -x -k "$FFTMP/$name.zip" "$FFTMP/$name"
  BINFILE="$(find "$FFTMP/$name" -type f -iname "$name*" | head -n 1)"
  [ -n "$BINFILE" ] || die "zip 中未找到 $name"
  cp "$BINFILE" "$PKG/ffmpeg/$name"
  chmod +x "$PKG/ffmpeg/$name"
  codesign -s - --force "$PKG/ffmpeg/$name" 2>/dev/null || true
done
"$PKG/ffmpeg/ffmpeg"  -version | head -n 1
"$PKG/ffmpeg/ffprobe" -version | head -n 1

# ---------------------------------------------------------------------------
# 7. 生成 启动.command 与 使用说明
# ---------------------------------------------------------------------------
log "生成 启动.command 与 使用说明-Mac.txt"
cat > "$PKG/启动.command" <<'LAUNCH'
#!/bin/bash
# pyvideotrans 绿色版启动脚本
DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$DIR" || exit 1
export PYTHONNOUSERSITE=1
export HF_ENDPOINT="https://hf-mirror.com"
export QT_API=pyside6
PYBIN="$(find "$DIR/runtime" -type f -name python3.10 -path '*/bin/*' | head -n 1)"
if [ -z "$PYBIN" ]; then
  echo "未找到内置 Python（$DIR/runtime），请确认解压完整。"
  exit 1
fi
exec "$PYBIN" sp.py
LAUNCH
chmod +x "$PKG/启动.command"

cat > "$PKG/使用说明-Mac.txt" <<'README'
pyvideotrans for macOS（绿色版）
================================

【首次运行】
1. 建议把本文件夹放在路径不含空格的位置（如「应用程序」或桌面）。
2. 双击「启动.command」。
   - 若 macOS 提示「无法打开，因为无法验证开发者」，任选一种：
     a) 右键点击「启动.command」→「打开」→ 再点「打开」（只需一次）；
     b) 打开「终端」，cd 到本文件夹后执行：xattr -cr .
3. 首次启动会出现启动画面与用户协议窗口，同意后进入主界面。

【已内置，开箱即用】
- 独立 Python 运行时（runtime/）：无需安装任何 Python。
- SenseVoiceSmall 语音识别模型 + 中文标点模型（models/）：语音转录完全离线。
- ffmpeg / ffprobe（ffmpeg/）。
- 默认已选好：发音语言=简体中文、识别=阿里FunASR(内置)、
  模型=SenseVoiceSmall、输出=txt。

【语音转录用法】
左侧菜单「语音转录」→ 拖入音频/视频文件 → 点「开始」。
纯文本结果输出在 output/ 目录（.txt）。

【联网说明】
- 语音转录（SenseVoiceSmall）完全离线可用。
- 勾选「降噪」首次使用需联网自动下载组件。
- 切换其他识别模型（如 faster-whisper）会按需联网下载到 models/。
- 在线翻译/配音渠道需自行配置相应账号密钥。

【常见问题】
- Apple 芯片 Mac 上 CUDA 加速不可用（选项自动隐藏），使用 CPU 推理，
  10 秒中文音频约几秒完成，属正常速度。
- 启动或转录报错时，查看 logs/ 目录下的日志文件。
README

# ---------------------------------------------------------------------------
# 8. 冒烟测试
# ---------------------------------------------------------------------------
log "冒烟测试：依赖导入"
"$PYBIN" - <<'PYEOF'
import torch, torchaudio, PySide6, funasr, modelscope, soundfile
print("deps ok:", torch.__version__)
PYEOF

log "冒烟测试：offscreen 启动 GUI 40 秒"
QT_QPA_PLATFORM=offscreen "$PYBIN" sp.py > "$BUILD_DIR/smoke.log" 2>&1 &
SMOKE_PID=$!
sleep 40
if kill -0 "$SMOKE_PID" 2>/dev/null; then
  echo "[ok] GUI 进程存活 40 秒，强制结束"
else
  echo "[warn] GUI 进程提前退出（CI 无头环境不阻塞打包），日志尾部:" >&2
  tail -n 40 "$BUILD_DIR/smoke.log" >&2 || true
fi
# 无论哪种结果都强杀并清理派生进程，确保不挂住 job
kill -9 "$SMOKE_PID" 2>/dev/null || true
pkill -9 -f "sp\.py" 2>/dev/null || true
wait 2>/dev/null || true
tail -n 5 "$BUILD_DIR/smoke.log" || true

# ---------------------------------------------------------------------------
# 9. 打包 zip
# ---------------------------------------------------------------------------
log "生成 zip"
cd "$BUILD_DIR"
rm -f "sp-mac-portable-$ARCH.zip"
ditto -c -k --keepParent "sp-mac-portable" "sp-mac-portable-$ARCH.zip"
du -sh "sp-mac-portable-$ARCH.zip"
log "构建完成: $BUILD_DIR/sp-mac-portable-$ARCH.zip"
