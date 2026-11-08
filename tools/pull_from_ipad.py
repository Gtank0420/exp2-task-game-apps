"""USB か同じ Wi-Fi でつないだ iPad (課題アプリ、1台版) か iPhone (ゲームアプリ) から、データを Mac に丸ごと写して検証する。

    python3 tools/pull_from_ipad.py <保存先フォルダ> [--app task|game|single] [--device <名前 または UDID>]

AirDrop で送れないとき (電池切れ寸前、アプリの不具合など) の予備の取り出し方。
アプリの Documents フォルダ全体を <保存先>/<日時>/ に写す。毎回新しいフォルダを作るので、
前に写したものを上書きしない。端末側のファイルは読むだけで、消したり変えたりしない。
写したあと validate_session.py と同じ検証をかける (ERROR が1つでもあれば終了コード 1)。

Xcode (xcrun devicectl) が必要。端末は「このコンピュータを信頼」済みであること。
"""

import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from exp2.game_load import game_session_folders  # noqa: E402
from exp2.game_validate import validate_game_session  # noqa: E402
from exp2.ipad import APPS, find_device, is_installed, pull_documents  # noqa: E402
from exp2.load import session_folders  # noqa: E402
from exp2.single_load import single_session_folders  # noqa: E402
from exp2.single_validate import validate_single_session  # noqa: E402
from exp2.validate import format_report, validate_session  # noqa: E402


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("dest", type=Path, help="保存先 (この下に日時のフォルダを作る)")
    parser.add_argument("--app", choices=sorted(APPS), default="task", help="task: 課題アプリ (iPad)、game: ゲームアプリ (iPhone)、single: 1台版 (iPad)")
    parser.add_argument("--device", help="端末の名前か UDID (その種類の実機が1台なら省略可)")
    args = parser.parse_args()
    target = APPS[args.app]

    udid = find_device(args.device, target.device_kind)
    if not is_installed(udid, target.bundle_id):
        print(f"この{target.device_kind}にはアプリ ({target.bundle_id}) が入っていません", file=sys.stderr)
        return 1
    out = pull_documents(udid, args.dest, target.bundle_id)

    data = out / target.data_folder
    if not data.is_dir():
        print(f"{target.data_folder} がありません (まだ1人も記録していない)")
        return 0
    if args.app == "task":
        folders, validate = session_folders(data), validate_session
    elif args.app == "single":
        folders, validate = single_session_folders(data), validate_single_session
    else:
        folders, validate = game_session_folders(data), validate_game_session
    n_ng = 0
    for folder in folders:
        issues = [i for i in validate(folder) if i.level != "INFO"]
        n_ng += any(i.level == "ERROR" for i in issues)
        print(format_report(folder, issues))
    print(f"\n{len(folders)} 人中 {len(folders) - n_ng} 人 OK、{n_ng} 人 NG")
    return 1 if n_ng else 0


if __name__ == "__main__":
    sys.exit(main())
