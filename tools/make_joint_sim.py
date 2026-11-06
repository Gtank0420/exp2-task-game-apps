"""2つのアプリ (課題アプリ、ゲームアプリ) と AirPods の IMU の、矛盾のない疑似データをまとめて作る。

    .venv/bin/python tools/make_joint_sim.py --out <出力先> [--n 20] [--seed 1] [--short]
        [--iphone-offset-ms <ID>=<ms> ...] [--game-id <ID>=<iPhone に入れた ID> ...]
        [--no-imu-stalls] [--legacy-imu-db [--imu-offset-ms <ID>=<ms> ...]]

1. 人ごとの筋書き (自由区間で、いつ計算し、いつゲームをし、いつぼんやりしていたか) を作る (exp2/scenario.py)
2. exp2-simulate --app joint で、筋書きどおりに2つのアプリの本物の記録処理を同じ時間の流れで動かす
3. 正解と頭振りの合図の時刻から、AirPods の IMU を合成し、課題アプリと同じ形で被験者フォルダに書く (exp2/imu_synth.py)
4. 書き出したデータを検証する

出力先の下にできるもの:
    exp2_data/DEV_JOINT01/ ...   課題アプリ (iPad) の記録。AirPods の IMU (headphone_motion.csv など) も入る
    exp2_game/DEV_JOINT01/ ...   ゲームアプリ (iPhone) の記録
    imu/DEV_JOINT01.db           --legacy-imu-db のときだけ。同じ動きを既存の IMU アプリの形 (SQLite) でも書く
    truth/DEV_JOINT01.csv        正解 (100 ms ごとの本当の状態。時刻は iPad の時計)
    scenarios/DEV_JOINT01.json   筋書き

分析コードの開発用。値の大きさに意味はない。統合スクリプト (exp2/timeline.py) が状態を正しく復元できるか、
時計のずれや ID の食い違いに気づけるかを試すために、--iphone-offset-ms や --game-id で問題を入れられる
(例: --iphone-offset-ms DEV_JOINT02=3000 で、2人目の iPhone の時計を 3 秒進める)。
AirPods の IMU は 2026-11-04 から課題アプリが iPad の時計で記録する (app_decisions #72) ので、時計のずれは入れられない。
--imu-offset-ms は、予備の経路 (既存の IMU アプリ、--legacy-imu-db) の時計のずれを試すときだけ使う。
同じ ID のフォルダが既にあれば止まる (上書きしない)。
"""

import argparse
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import pandas as pd  # noqa: E402

from exp2.game_validate import validate_game_session  # noqa: E402
from exp2.imu_synth import (  # noqa: E402
    ImuSynthConfig,
    synthesize_headphone,
    synthesize_imu,
    write_headphone_csv,
    write_imu_sqlite,
)
from exp2.load import load_session  # noqa: E402
from exp2.scenario import make_scenario  # noqa: E402
from exp2.validate import validate_session  # noqa: E402

APP_ROOT = Path(__file__).resolve().parents[1]


def parse_map(items: list[str] | None, cast=int) -> dict:
    out = {}
    for item in items or []:
        key, _, value = item.partition("=")
        if not value:
            sys.exit(f"<ID>=<値> の形で指定してください: {item}")
        out[key] = cast(value)
    return out


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--n", type=int, default=20)
    parser.add_argument("--seed", type=int, default=1)
    parser.add_argument("--short", action="store_true", help="区間を短縮する (自由区間 60 秒)。動作確認用")
    parser.add_argument("--iphone-offset-ms", nargs="*", help="<ID>=<ms>: iPhone の時計のずれ")
    parser.add_argument("--imu-offset-ms", nargs="*", help="<ID>=<ms>: 既存の IMU アプリの端末の時計のずれ (--legacy-imu-db のとき)")
    parser.add_argument("--game-id", nargs="*", help="<ID>=<ID>: iPhone に入れた ID (食い違いを試す)")
    parser.add_argument("--no-imu-stalls", action="store_true", help="受け取りの止まりを入れない")
    parser.add_argument("--legacy-imu-db", action="store_true",
                        help="同じ動きを既存の IMU アプリの形 (imu/<ID>.db) でも書く (予備の経路の確認用)")
    args = parser.parse_args()

    iphone_offsets = parse_map(args.iphone_offset_ms)
    imu_offsets = parse_map(args.imu_offset_ms)
    game_ids = parse_map(args.game_id, cast=str)

    print("[1/4] 筋書きを作ります")
    scenario_dir = args.out / "scenarios"
    scenarios = []
    for i in range(args.n):
        pid = f"DEV_JOINT{i + 1:02d}"
        s = make_scenario(i, seed=args.seed, short=args.short, iphone_unix_offset_ms=iphone_offsets.get(pid, 0),
                          imu_unix_offset_ms=imu_offsets.get(pid, 0), game_participant_id=game_ids.get(pid))
        if (scenario_dir / f"{pid}.json").exists():
            sys.exit(f"筋書きが既にあります (上書きしません): {scenario_dir / f'{pid}.json'}")
        s.write(scenario_dir)
        scenarios.append(s)

    print("[2/4] 2つのアプリの記録を作ります (1人あたり数秒)")
    r = subprocess.run(["swift", "run", "--package-path", str(APP_ROOT / "Packages/ExperimentCore"), "exp2-simulate",
                        "--app", "joint", "--scenario-dir", str(scenario_dir), "--out", str(args.out)],
                       capture_output=True, text=True)
    print("\n".join(line for line in r.stdout.splitlines() if line.startswith("DEV_")))
    if r.returncode != 0:
        sys.exit(f"exp2-simulate が失敗しました:\n{r.stderr[-2000:]}")

    print("[3/4] AirPods の IMU を合成します")
    imu_cfg = ImuSynthConfig(stalls=not args.no_imu_stalls)
    for s in scenarios:
        truth = pd.read_csv(args.out / "truth" / f"{s.participant_id}.csv")
        folder = args.out / "exp2_data" / s.participant_id
        task = load_session(folder)
        ev = task.events
        shakes = ev[ev["event_type"] == "shake_prompt_on"]["unix_ms"].tolist()
        # 課題アプリの記録の始め (セッションの作成) から完了画面まで記録する (本番と同じ)
        motion, hevents = synthesize_headphone(truth, shakes, task.meta["created_at"], int(ev["unix_ms"].max()),
                                               s.participant_id, seed=s.seed, cfg=imu_cfg)
        write_headphone_csv(motion, hevents, folder)
        if args.legacy_imu_db:
            df = synthesize_imu(truth, shakes, int(ev["unix_ms"].min()) - imu_cfg.lead_ms,
                                int(ev["unix_ms"].max()) + imu_cfg.tail_ms, seed=s.seed,
                                unix_offset_ms=s.imu_unix_offset_ms, cfg=imu_cfg)
            write_imu_sqlite(df, args.out / "imu" / f"{s.participant_id}.db")

    print("[4/4] 検証します")
    n_ng = 0
    for s in scenarios:
        imu_db = args.out / "imu" / f"{s.participant_id}.db" if args.legacy_imu_db else None
        issues = validate_session(args.out / "exp2_data" / s.participant_id, imu_db=imu_db)
        issues += validate_game_session(args.out / "exp2_game" / s.game_participant_id)
        errors = [i for i in issues if i.level == "ERROR"]
        warns = [i for i in issues if i.level == "WARN" and "IMU の受信時刻" not in i.message]
        n_ng += bool(errors)
        status = "NG" if errors else "OK"
        print(f"  {s.participant_id}: {status}  サボりの割合 {s.offtask_fraction:.2f}"
              + "".join(f"\n    {i}" for i in errors + warns))
    print(f"\n{len(scenarios)} 人中 {len(scenarios) - n_ng} 人 OK。出力先: {args.out}")
    return 1 if n_ng else 0


if __name__ == "__main__":
    sys.exit(main())
