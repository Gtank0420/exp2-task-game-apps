"""USB でつないだ iPad / iPhone を xcrun devicectl で扱う (tools/pull_from_ipad.py と tools/install_to_ipad.py で使う)。

課題アプリ (iPad) とゲームアプリ (研究室の iPhone) と1台版 (iPad) を扱う。どれかは --app task / game / single で選ぶ。
一度 USB でつないで信頼した端末は、Mac と同じ Wi-Fi にいればケーブルなしでも扱える (devicectl がネットワーク越しにつなぐ)。
"""

from __future__ import annotations

import json
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path


@dataclass(frozen=True)
class AppTarget:
    """入れ直し・取り出しの対象のアプリ"""
    bundle_id: str
    scheme: str
    product: str
    data_folder: str
    meta_file: str
    device_kind: str  # "iPad" / "iPhone" (メッセージと、つながっている機器の絞り込みに使う)


APPS = {
    "task": AppTarget("com.ryogashimizu.Exp2Task", "Exp2Task", "Exp2Task.app", "exp2_data", "meta.json", "iPad"),
    "game": AppTarget("com.ryogashimizu.Exp2Game", "Exp2Game", "Exp2Game.app", "exp2_game", "game_meta.json", "iPhone"),
    # 1台版 (docs/single_decisions.md S1、S2)。課題アプリと同じ iPad に入るが、bundle ID が違うのでデータの場所も別
    "single": AppTarget("com.ryogashimizu.Exp2Single", "Exp2Single", "Exp2Single.app", "exp2_single", "meta.json", "iPad"),
}

BUNDLE_ID = APPS["task"].bundle_id


def devicectl(*args: str) -> subprocess.CompletedProcess:
    return subprocess.run(["xcrun", "devicectl", *args], capture_output=True, text=True)


def find_device(name: str | None, kind: str = "iPad") -> str:
    """つながっている実機の UDID を返す。name を省くと、その種類 (iPad / iPhone) の実機が1台だけのときにそれを使う。"""
    with tempfile.TemporaryDirectory() as tmp:
        out = Path(tmp) / "devices.json"
        r = devicectl("list", "devices", "--json-output", str(out), "--quiet")
        if r.returncode != 0:
            sys.exit(f"機器の一覧を取れません:\n{r.stderr}")
        devices = json.loads(out.read_text())["result"]["devices"]
    physical = [
        d for d in devices
        if d.get("hardwareProperties", {}).get("reality") == "physical"
        and d.get("connectionProperties", {}).get("tunnelState") != "unavailable"
    ]
    if name:
        physical = [d for d in physical
                    if name in (d["deviceProperties"].get("name"), d["hardwareProperties"].get("udid"))]
    else:
        # iPad と iPhone を両方つないでいても選べるよう、種類で絞る (種類が分からない機器は残す)
        physical = [d for d in physical if d.get("hardwareProperties", {}).get("deviceType", kind) == kind]
    if len(physical) != 1:
        names = [d["deviceProperties"].get("name") for d in physical]
        sys.exit(f"{kind} を1台に決められません (見つかった実機: {names})。--device で名前か UDID を指定してください")
    d = physical[0]
    print(f"{kind}: {d['deviceProperties'].get('name')} ({d['hardwareProperties']['udid']})")
    return d["hardwareProperties"]["udid"]


def is_installed(udid: str, bundle_id: str) -> bool:
    """そのアプリが端末に入っているか (入っていないと、データを写すときに分かりにくいエラーになる)"""
    with tempfile.TemporaryDirectory() as tmp:
        out = Path(tmp) / "apps.json"
        r = devicectl("device", "info", "apps", "--device", udid, "--bundle-id", bundle_id,
                      "--json-output", str(out), "--quiet")
        if r.returncode != 0:
            sys.exit(f"端末のアプリの一覧を取れません:\n{r.stderr or r.stdout}")
        return bool(json.loads(out.read_text())["result"]["apps"])


def pull_documents(udid: str, dest: Path, bundle_id: str = BUNDLE_ID) -> Path:
    """アプリの Documents フォルダ全体を dest/<日時>/ に写し、そのフォルダを返す。

    毎回新しいフォルダを作るので、前に写したものを上書きしない。端末側は読むだけ。
    """
    out = Path(dest) / datetime.now().strftime("%Y%m%d-%H%M%S")
    out.mkdir(parents=True, exist_ok=False)  # 既にあれば止める (上書きしない)
    # devicectl は写し先のフォルダが先にないと失敗する
    r = devicectl("device", "copy", "from", "--device", udid,
                  "--domain-type", "appDataContainer", "--domain-identifier", bundle_id,
                  "--source", "Documents", "--destination", str(out))
    if r.returncode != 0:
        sys.exit(f"写せませんでした:\n{r.stderr or r.stdout}")
    print(f"写した先: {out}")
    return out
