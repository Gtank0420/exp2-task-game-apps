"""課題アプリ (iPad)、ゲームアプリ (iPhone)、1台版 (iPad) を USB か同じ Wi-Fi でつないだ端末に入れ直し、データが残っていることを確かめる。

    python3 tools/install_to_ipad.py <バックアップ先> [--app task|game|single] [--renew] [--device <名前 または UDID>]

--app task (既定) は課題アプリを iPad に、--app game はゲームアプリを研究室の iPhone に、--app single は1台版を iPad に入れる。
1台版と課題アプリは同じ iPad に並べて入れられる (bundle ID が違うので、片方を入れ直してももう片方のデータには触れない)。

無料の Apple アカウントの署名は7日で切れ、切れるとアプリが開かなくなる。そのたびにこれで入れ直す。
1. 入れ直す前に、アプリの Documents フォルダ全体を <バックアップ先>/<日時>/ に写す
2. ビルドして入れ直す (上から入れるので、端末のデータは消えない。アプリを端末で削除しないこと)
3. もう一度写し、1 と中身がすべて同じかを比べる
4. 新しい署名の期限を表示する

署名は、まだ切れていなければ同じものが使い回され、期限が延びないことがある。
期限前に延ばしたいときは --renew を付ける。Mac に保存された古い署名ファイル
(~/Library/Developer/Xcode/UserData/Provisioning Profiles/ のうち、このアプリのもの) を
<バックアップ先>/<日時>/old_profiles/ に移してからビルドし、Xcode に新しく作らせる (消さずに移すだけ)。
"""

import argparse
import filecmp
import plistlib
import shutil
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from exp2.ipad import APPS, devicectl, find_device, is_installed, pull_documents  # noqa: E402

APP_ROOT = Path(__file__).resolve().parents[1]
DERIVED = APP_ROOT / "build/DerivedData"
PROFILES = Path.home() / "Library/Developer/Xcode/UserData/Provisioning Profiles"


def read_profile(path: Path) -> dict:
    """署名ファイル (.mobileprovision) の中身を読む。"""
    r = subprocess.run(["security", "cms", "-D", "-i", str(path)], capture_output=True)
    return plistlib.loads(r.stdout)


def is_this_app(profile: dict, bundle_id: str) -> bool:
    app_id = profile.get("Entitlements", {}).get("application-identifier", "")
    return app_id.endswith("." + bundle_id)


def move_old_profiles(dest: Path, bundle_id: str) -> None:
    dest.mkdir(parents=True)
    moved = [p for p in PROFILES.glob("*.mobileprovision") if is_this_app(read_profile(p), bundle_id)]
    for p in moved:
        shutil.move(str(p), dest / p.name)
    print(f"古い署名ファイル {len(moved)} 個を {dest} に移しました")


def same_tree(a: Path, b: Path) -> list[str]:
    """a の中のファイルが、b に同じ中身ですべてあるか。違うファイルの一覧を返す。"""
    if not a.is_dir():  # まだ1人も記録していない
        return []
    diffs = []
    for f in sorted(p for p in a.rglob("*") if p.is_file()):
        g = b / f.relative_to(a)
        if not g.is_file():
            diffs.append(f"なくなった: {f.relative_to(a)}")
        elif not filecmp.cmp(f, g, shallow=False):
            diffs.append(f"中身が違う: {f.relative_to(a)}")
    return diffs


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("backup", type=Path, help="入れ直しの前後に写すデータの保存先")
    parser.add_argument("--app", choices=sorted(APPS), default="task", help="task: 課題アプリ (iPad)、game: ゲームアプリ (iPhone)、single: 1台版 (iPad)")
    parser.add_argument("--renew", action="store_true", help="古い署名を使わず、新しく作らせる")
    parser.add_argument("--device", help="端末の名前か UDID (その種類の実機が1台なら省略可)")
    args = parser.parse_args()
    target = APPS[args.app]
    app = DERIVED / "Build/Products/Debug-iphoneos" / target.product

    udid = find_device(args.device, target.device_kind)

    print("\n[1/4] 入れ直す前のデータを写します")
    if is_installed(udid, target.bundle_id):
        before = pull_documents(udid, args.backup, target.bundle_id)
    else:
        # 初めて入れるときは写すものがない。--renew の置き場所と 3 の比べる相手として空のフォルダを作る
        before = args.backup / datetime.now().strftime("%Y%m%d-%H%M%S")
        before.mkdir(parents=True, exist_ok=False)
        print("アプリがまだ入っていないので、初めて入れます")
    n_before = len(list((before / target.data_folder).glob(f"*/{target.meta_file}")))
    print(f"被験者フォルダ {n_before} 人分")

    print("\n[2/4] ビルドして入れ直します (数分かかります)")
    if args.renew:
        move_old_profiles(before / "old_profiles", target.bundle_id)
    build = subprocess.run(
        ["xcodebuild", "-project", str(APP_ROOT / "Exp2Task.xcodeproj"), "-scheme", target.scheme,
         "-configuration", "Debug", "-destination", f"id={udid}", "-derivedDataPath", str(DERIVED),
         "-allowProvisioningUpdates", "build"],
        capture_output=True, text=True,
    )
    if build.returncode != 0:
        errors = [line for line in build.stdout.splitlines() if "error" in line.lower()]
        sys.exit("ビルドに失敗しました。アプリは入れ直していません:\n" + "\n".join(errors[-15:]))
    r = devicectl("device", "install", "app", "--device", udid, str(app))
    if r.returncode != 0:
        sys.exit(f"インストールに失敗しました:\n{r.stderr or r.stdout}")
    print("入れ直しました")

    print("\n[3/4] 入れ直したあとのデータを写して、前と比べます")
    after = pull_documents(udid, args.backup, target.bundle_id)
    diffs = same_tree(before / target.data_folder, after / target.data_folder)
    if diffs:
        print(f"入れ直しの前後でデータが違います。{target.device_kind} のアプリは削除せず、そのままにしてください:")
        print("\n".join("  " + d for d in diffs))
        return 1
    print(f"OK: {n_before} 人分のデータが、入れ直しの前とすべて同じ中身で残っています")

    print("\n[4/4] 署名の期限")
    expires = read_profile(app / "embedded.mobileprovision")["ExpirationDate"].replace(tzinfo=timezone.utc)
    left = expires - datetime.now(timezone.utc)
    local = expires.astimezone().strftime("%Y-%m-%d %H:%M")
    print(f"期限: {local} (あと {left.days} 日 {left.seconds // 3600} 時間)。この時刻を過ぎるとアプリが開かなくなります")
    if left.days < 6:
        print("期限が延びていません。延ばしたいときは --renew を付けてもう一度実行してください")
    return 0


if __name__ == "__main__":
    sys.exit(main())
