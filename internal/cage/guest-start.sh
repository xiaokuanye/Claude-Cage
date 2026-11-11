#!/usr/bin/env bash
set -euo pipefail
for app in code-server chromium X0tigervnc Xtigervnc openbox websockify; do
  command -v "$app" >/dev/null || { echo "Missing $app; run cage setup first." >&2; exit 1; }
done
mkdir -p "$HOME/.config/claude-cage"
chmod 700 "$HOME/.config/claude-cage"
if [ ! -s "$HOME/.config/claude-cage/code-server.yaml" ]; then
  (umask 077; printf 'auth: password\npassword: %s\ncert: false\n' "$(od -An -N24 -tx1 /dev/urandom | tr -d ' \n')" > "$HOME/.config/claude-cage/code-server.yaml")
fi
if [ ! -s "$HOME/.config/claude-cage/browser-password" ]; then
  (umask 077; od -An -N4 -tx1 /dev/urandom | tr -d ' \n' > "$HOME/.config/claude-cage/browser-password")
fi
sudo install -d -o cage-browser -g cage-browser -m 0700 /home/cage-browser/.vnc
cat "$HOME/.config/claude-cage/browser-password" | sudo -u cage-browser sh -c 'umask 077; tigervncpasswd -f > "$HOME/.vnc/passwd"'
sudo systemctl stop cage-browser || true
# Existing images may predate the explicit locale dependency. The scoped
# maintenance channel can install it while business networking stays closed.
if ! cage_is_ubuntu && ! dpkg-query -W -f='${Status}' chromium-l10n 2>/dev/null | grep -qx 'install ok installed'; then
  sudo env DEBIAN_FRONTEND=noninteractive APT_CONFIG="${CAGE_APT_CONFIG:-/dev/null}" apt-get update </dev/null
  sudo env DEBIAN_FRONTEND=noninteractive APT_CONFIG="${CAGE_APT_CONFIG:-/dev/null}" apt-get install -y --no-install-recommends chromium-l10n </dev/null
fi
# Publish per-VM control credentials for the browser process and SSH owner only.
sudo env CAGE_DISPLAY_SCALE="${CAGE_DISPLAY_SCALE:-2}" CAGE_WORKSPACE="$PWD" CAGE_USER_HOME="$HOME" python3 - <<'PYCONTROL'
import json, os, secrets, grp
from pathlib import Path
p=Path('/etc/claude-cage/browser-control.json')
d=json.loads(p.read_text()) if p.exists() else {'token':secrets.token_hex(32)}
scale = 1.5 if os.environ['CAGE_DISPLAY_SCALE'] == '1.5' else 2
d['display_scale'] = scale
# With a settings manager each viewer chooses the density of its own screen.
d['dynamic_scale'] = all(os.access(tool, os.X_OK) for tool in ('/usr/bin/xsettingsd', '/usr/bin/dump_xsettings'))
scale_file = Path('/etc/claude-cage/display-scale')
scale_file.write_text(str(scale) + '\n')
scale_file.chmod(0o644)
d['workspace']=os.environ['CAGE_WORKSPACE']
yaml=Path(os.environ['CAGE_USER_HOME']) / '.config/claude-cage/code-server.yaml'
d['editorPassword']=next(line.split(':',1)[1].strip() for line in yaml.read_text().splitlines() if line.startswith('password:'))
p.write_text(json.dumps(d))
p.chmod(0o640)
os.chown(p,0,grp.getgrnam('cage-browser').gr_gid)
PYCONTROL
sudo -u cage-browser env CAGE_LANGUAGE="$CAGE_LANGUAGE" python3 - <<'PYCODE'
import json, os
from pathlib import Path
p = Path.home() / "profile/Default/Preferences"
p.parent.mkdir(parents=True, exist_ok=True)
d = json.loads(p.read_text()) if p.exists() else {}
d.setdefault("intl", {})["accept_languages"] = os.environ["CAGE_LANGUAGE"]
d["intl"]["selected_languages"] = os.environ["CAGE_LANGUAGE"]
d.setdefault("translate", {})["enabled"] = False
d["credentials_enable_service"] = False
d.setdefault("profile", {})["password_manager_enabled"] = False
p.write_text(json.dumps(d))
PYCODE
sudo systemctl reset-failed cage-display cage-window-manager cage-browser cage-vnc cage-webvnc 2>/dev/null || true
sudo systemctl reset-failed cage-display-governor 2>/dev/null || true
sudo systemctl restart cage-display cage-window-manager cage-browser cage-vnc cage-webvnc
# Seed only appearance settings for a new editor profile. Existing preferences stay intact.
python3 - <<'PYEDITOR'
import shutil
from pathlib import Path
p = Path.home() / '.local/share/code-server/User/settings.json'
if not p.exists():
    p.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile('/etc/claude-cage/editor-theme.json', p)
PYEDITOR
# Systemd owns the editor independently of the SSH session and restarts crashes.
(umask 077; printf '%s' "$PWD" > "$HOME/.config/claude-cage/editor-workspace")
if ! systemctl is-active --quiet cage-editor.service; then
  sudo /usr/local/bin/cage-editor-migrate
  sudo systemctl start cage-editor.service
fi
sudo python3 /usr/local/lib/cage-wait-services.py
printf 'Cage services ready. Timezone=%s Locale=%s Browser=%s\n' "$CAGE_TZ" "$CAGE_LOCALE" "$CAGE_LANGUAGE"
