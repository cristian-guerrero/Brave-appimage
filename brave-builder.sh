#!/usr/bin/env bash

# CONFIGURATION
APP=brave
ROOT_DIR=$(pwd)
FLAVOR="browser"
CHANNELS=()

# Parse arguments
for arg in "$@"; do
	case $arg in
		origin) FLAVOR="origin" ;;
		stable|beta|nightly) CHANNELS+=("$arg") ;;
	esac
done

# Default channels if none specified
if [ ${#CHANNELS[@]} -eq 0 ]; then
	if [ "$FLAVOR" = "origin" ]; then
		CHANNELS=("nightly")
	else
		CHANNELS=("stable" "beta")
	fi
fi

if [ "$FLAVOR" = "origin" ]; then
	APP_NAME="brave-origin"
	DOWNLOAD_PATTERN="brave-origin"
	BRANDING="Brave Origin"
else
	APP_NAME="brave-browser"
	DOWNLOAD_PATTERN="brave-browser"
	BRANDING="Brave"
fi

# TEMPORARY DIRECTORY
mkdir -p tmp
cd ./tmp || exit 1

# DOWNLOAD APPIMAGETOOL
if ! test -f ./appimagetool; then
	wget -q https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-x86_64.AppImage -O appimagetool || exit 1
	chmod a+x ./appimagetool
fi

# FETCH LIST OF RELEASES
Stable=$(curl -Ls https://api.github.com/repos/brave/brave-browser/releases/latest | sed 's/[()",{} ]/\n/g' | grep -oi "https.*download.*linux.*zip$" | grep -v "symbol")
Releases=$(curl -Ls https://api.github.com/repos/brave/brave-browser/releases?per_page=100 | sed 's/[()",{} ]/\n/g' | grep -oi "https.*download.*linux.*zip$" | grep -v "symbol")
LIST=$(printf "%b\n%b\n" "$Stable" "$Releases" | grep . )

if [ -z "$LIST" ]; then
	echo "Error: Could not retrieve release list from GitHub."
	exit 1
fi

# Use local launcher if available, otherwise fallback to remote
if [ -f "$ROOT_DIR/brave.desktop" ]; then
	LAUNCHER_FILE="$ROOT_DIR/brave.desktop"
else
	wget -q https://raw.githubusercontent.com/ivan-hc/Brave-appimage/main/brave.desktop -O brave.desktop
	LAUNCHER_FILE="$(pwd)/brave.desktop"
fi

_create_brave_appimage() {
	if [ "$CHANNEL" != "stable" ]; then
		DOWNLOAD_URL=$(echo "$LIST" | grep -i "$DOWNLOAD_PATTERN-$CHANNEL.*$archref" | head -1)
	else
		# For stable, sometimes it doesn't have "-stable" in name
		DOWNLOAD_URL=$(echo "$LIST" | grep -v "beta\|nightly" | grep -i "$DOWNLOAD_PATTERN.*$archref" | head -1)
	fi
	
	if [ -z "$DOWNLOAD_URL" ]; then
		echo "Warning: Could not find download URL for $BRANDING $CHANNEL ($archref). Skipping."
		return 0
	fi

	echo "Downloading $BRANDING $CHANNEL ($archref)..."
	if wget --version | head -1 | grep -q ' 1.'; then
		wget -q --no-verbose --show-progress --progress=bar "$DOWNLOAD_URL" -O "brave-$archref.zip" || exit 1
	else
		wget -q "$DOWNLOAD_URL" -O "brave-$archref.zip" || exit 1
	fi
	
	mkdir -p "$APP"-"$arch".AppDir
	unzip -qq "brave-$archref.zip" -d "$APP"-"$arch".AppDir/ || exit 1
	cd "$APP"-"$arch".AppDir || exit 1
	cp "$LAUNCHER_FILE" brave.desktop
	
	# Determine binary name from zip content
	BINARY_NAME=$(ls brave-origin-$CHANNEL 2>/dev/null || ls brave-browser-$CHANNEL 2>/dev/null || ls brave-browser 2>/dev/null || ls brave 2>/dev/null | head -1)
	[ -z "$BINARY_NAME" ] && BINARY_NAME="brave"

	# Branding and Icons
	if [ "$CHANNEL" != "stable" ] || [ "$FLAVOR" != "browser" ]; then
		DISPLAY_NAME="$BRANDING ${CHANNEL^}"
		WM_CLASS="$APP_NAME-$CHANNEL"
		ICON_NAME="$APP_NAME-$CHANNEL"
		sed -i "s/^Name=Brave/Name=$DISPLAY_NAME/g; s/^StartupWMClass=brave-browser/StartupWMClass=$WM_CLASS/g" brave.desktop
		cp ./*128*.png "$ICON_NAME.png" 2>/dev/null || cp ./*.png "$ICON_NAME.png" 2>/dev/null
		sed -i "s#^Icon=.*#Icon=$ICON_NAME#g" brave.desktop
	else
		cp ./*128*.png brave.png 2>/dev/null || cp ./*.png brave.png 2>/dev/null
		sed -i "s#^Icon=.*#Icon=brave#g" brave.desktop
	fi
	cd .. || exit 1

	VERSION=$(echo "$DOWNLOAD_URL" | tr '/-' '\n' | grep "^[0-9].*" | head -1)
	
	# Profile directory name for separation
	if [ "$FLAVOR" = "origin" ]; then
		PROFILE_NAME="Brave-Browser-Origin-${CHANNEL^}"
	else
		if [ "$CHANNEL" = "stable" ]; then
			PROFILE_NAME="Brave-Browser"
		else
			PROFILE_NAME="Brave-Browser-${CHANNEL^}"
		fi
	fi

	# Create AppRun
	cat <<-HEREDOC > ./"$APP"-"$arch".AppDir/AppRun
	#!/bin/sh
	HERE="\$(dirname "\$(readlink -f "\${0}")")"
	export UNION_PRELOAD="\${HERE}"
	exec "\${HERE}"/$BINARY_NAME --user-data-dir="\$HOME/.config/BraveSoftware/$PROFILE_NAME" --class="$WM_CLASS" "\$@"
	HEREDOC
	chmod a+x ./"$APP"-"$arch".AppDir/AppRun

	# Build AppImage
	ARCH="$arch" ./appimagetool --comp zstd --mksquashfs-opt -Xcompression-level --mksquashfs-opt 20 \
		-u "gh-releases-zsync|$GITHUB_REPOSITORY_OWNER|Brave-appimage|continuous-$CHANNEL-$FLAVOR|*-$CHANNEL-$FLAVOR-*$arch.AppImage.zsync" \
		./"$APP"-"$arch".AppDir "${BRANDING// /-}-$CHANNEL-$VERSION-$arch.AppImage" || exit 1
}

_create_brave_appimages() {
	architectures="x86_64 aarch64"
	for arch in $architectures; do
		if [ "$arch" = "x86_64" ]; then
			archref="amd64"
		else
			archref="arm64"
		fi
		_create_brave_appimage
	done
}

_build_channel() {
	CHANNEL="$1"
	mkdir -p "$CHANNEL-$FLAVOR" && cp ./appimagetool ./"$CHANNEL-$FLAVOR"/appimagetool && cd "$CHANNEL-$FLAVOR" || exit 1
	_create_brave_appimages
	cd .. || exit 1
	mv ./"$CHANNEL-$FLAVOR"/*.AppImage* ./
}

for channel in "${CHANNELS[@]}"; do
	_build_channel "$channel"
done

cd ..
mv ./tmp/*.AppImage* ./
rm -rf ./tmp
