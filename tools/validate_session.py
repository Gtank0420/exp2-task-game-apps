"""課題アプリ (iPad) とゲームアプリ (iPhone) の書き出しデータを検証する。

    python3 tools/validate_session.py <被験者フォルダ、exp2_data、exp2_game、またはその親> [--imu <IMU の .db>] [--quiet]

被験者フォルダの種類 (meta.json なら課題アプリ、game_meta.json ならゲームアプリ) を見分けて検証する。
親フォルダを指定すると、その下の exp2_data と exp2_game の両方を検証する。
AirPods の頭の動き (2026-11-04 から課題アプリが被験者フォルダに記録する。app_decisions #72) は自動で検証する。
--imu は、予備の経路として既存の IMU アプリで記録したときだけ使う。課題アプリの1人分のフォルダを指定したときだけ使える
(その人の IMU 記録と時間が重なるかを見る)。
--quiet を付けると INFO を出さない。ERROR が1つでもあれば終了コード 1。
"""

import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from exp2.game_load import game_session_folders  # noqa: E402
from exp2.game_validate import validate_game_session  # noqa: E402
from exp2.load import session_folders  # noqa: E402
from exp2.validate import format_report, validate_session  # noqa: E402


def find_folders(path: Path) -> list[tuple[str, Path]]:
    """(種類, 被験者フォルダ) の一覧。種類は "task" か "game"。"""
    if not path.is_dir():
        return []
    return [("task", f) for f in session_folders(path)] + [("game", f) for f in game_session_folders(path)]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("path", type=Path)
    parser.add_argument("--imu", type=Path)
    parser.add_argument("--quiet", action="store_true")
    args = parser.parse_args()

    folders = find_folders(args.path)
    if not folders:
        print(f"被験者フォルダが見つかりません: {args.path}", file=sys.stderr)
        return 1
    if args.imu and (len(folders) != 1 or folders[0][0] != "task"):
        print("--imu は課題アプリの1人分のフォルダを指定したときだけ使えます", file=sys.stderr)
        return 1

    n_ng = 0
    for kind, folder in folders:
        if kind == "task":
            issues = validate_session(folder, imu_db=args.imu)
        else:
            issues = validate_game_session(folder)
        if args.quiet:
            issues = [i for i in issues if i.level != "INFO"]
        n_ng += any(i.level == "ERROR" for i in issues)
        label = "課題" if kind == "task" else "ゲーム"
        print(f"[{label}] " + format_report(folder, issues))
    print(f"\n{len(folders)} 件中 {len(folders) - n_ng} 件 OK、{n_ng} 件 NG")
    return 1 if n_ng else 0


if __name__ == "__main__":
    sys.exit(main())
