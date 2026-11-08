"""1台版と AirPods の IMU の、矛盾のない疑似データをまとめて作る (分析コードの開発用)。

    .venv/bin/python tools/make_single_sim.py --out <出力先> [--n 20] [--seed 1] [--short] [--no-imu-stalls]

1. 人ごとの筋書き (ポップアップでどうしたか、いつぼんやりしたか) を作る (exp2/single_scenario.py)
2. exp2-single-simulate --scenario-dir で、筋書きどおりに1台版の本物の記録処理を動かし、正解を書く
3. 正解と頭振りの合図の時刻から、AirPods の IMU を合成し、1台版の被験者フォルダに書く (exp2/imu_synth.py)
4. 書き出したデータを検証する

出力先の下にできるもの:
    exp2_single/DEV_SJOINT01/ ...  1台版の記録。AirPods の IMU (headphone_motion.csv など) も入る
    truth/DEV_SJOINT01.csv         正解 (100 ms ごとの本当の状態。compute / game / onset / dismissed / idle / other)
    scenarios/DEV_SJOINT01.json    筋書き

2台版の tools/make_joint_sim.py と同じ考え方。IMU の合成は2台版と同じ部品を、1台版用の設定 (SINGLE_IMU) で使う。
値の大きさに意味はない。同じ ID のフォルダが既にあれば止まる (上書きしない)。
"""

import argparse
import subprocess
import sys
from dataclasses import replace
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import pandas as pd  # noqa: E402

from exp2.imu_synth import ImuSynthConfig, synthesize_headphone, write_headphone_csv  # noqa: E402
from exp2.single_load import load_single_session  # noqa: E402
from exp2.single_scenario import make_single_scenario  # noqa: E402
from exp2.single_validate import validate_single_session  # noqa: E402

APP_ROOT = Path(__file__).resolve().parents[1]

# 1台版の IMU の合成の設定。計算もゲームも同じ iPad の画面を見るので、ゲーム中のうつむき方は計算中とほぼ同じにし、
# 揺れだけを少し大きくする (設計書8.1: 姿勢の違いはほぼなくなる)。2台版 (ImuSynthConfig の既定) はゲーム中に深くうつむく
SINGLE_IMU = ImuSynthConfig(
    pitch=(("compute", -0.30), ("game", -0.32), ("idle", -0.12), ("other", -0.20)),
    rot_sigma=(("compute", 0.03), ("game", 0.05), ("idle", 0.15), ("other", 0.10)),
    acc_sigma=(("compute", 0.004), ("game", 0.008), ("idle", 0.02), ("other", 0.015)),
)


def imu_truth(truth: pd.DataFrame) -> pd.DataFrame:
    """imu_synth が読む形にする。imu_synth は「holding (iPhone を持っている) なら game」と読むので、
    1台版ではゲームの画面が出ている間を holding とし、出てから最初の操作までと遊ばずに閉じた回もゲームの姿勢にする。"""
    t = truth.copy()
    t["holding"] = t["game_screen"].astype(int)
    t["state"] = t["state"].replace({"onset": "game", "dismissed": "game"})
    return t


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--n", type=int, default=20)
    parser.add_argument("--seed", type=int, default=1)
    parser.add_argument("--short", action="store_true", help="区間を短縮する (自由区間 60 秒)。動作確認用")
    parser.add_argument("--no-imu-stalls", action="store_true", help="受け取りの止まりを入れない")
    args = parser.parse_args()

    print("[1/4] 筋書きを作ります")
    scenario_dir = args.out / "scenarios"
    scenarios = []
    for i in range(args.n):
        s = make_single_scenario(i, seed=args.seed, short=args.short)
        if (scenario_dir / f"{s.participant_id}.json").exists():
            sys.exit(f"筋書きが既にあります (上書きしません): {scenario_dir / f'{s.participant_id}.json'}")
        s.write(scenario_dir)
        scenarios.append(s)

    print("[2/4] 1台版の記録を作ります")
    r = subprocess.run(["swift", "run", "--package-path", str(APP_ROOT / "Packages/ExperimentCore"),
                        "exp2-single-simulate", "--scenario-dir", str(scenario_dir), "--out", str(args.out)],
                       capture_output=True, text=True)
    print("\n".join(line for line in r.stdout.splitlines() if line.startswith("DEV_")))
    if r.returncode != 0:
        sys.exit(f"exp2-single-simulate が失敗しました:\n{r.stderr[-2000:]}")

    print("[3/4] AirPods の IMU を合成します")
    cfg = replace(SINGLE_IMU, stalls=not args.no_imu_stalls)
    for s in scenarios:
        truth = imu_truth(pd.read_csv(args.out / "truth" / f"{s.participant_id}.csv"))
        folder = args.out / "exp2_single" / s.participant_id
        session = load_single_session(folder)
        ev = session.events
        shakes = ev[ev["event_type"] == "shake_prompt_on"]["unix_ms"].tolist()
        motion, hevents = synthesize_headphone(truth, shakes, session.meta["created_at"], int(ev["unix_ms"].max()),
                                               s.participant_id, seed=s.seed, cfg=cfg)
        write_headphone_csv(motion, hevents, folder)

    print("[4/4] 検証します")
    n_ng = 0
    for s in scenarios:
        issues = validate_single_session(args.out / "exp2_single" / s.participant_id)
        errors = [i for i in issues if i.level == "ERROR"]
        warns = [i for i in issues if i.level == "WARN"]
        n_ng += bool(errors)
        print(f"  {s.participant_id}: {'NG' if errors else 'OK'}  遊ぶ確率 {s.play_probability:.2f}、"
              f"1回に遊ぶ長さ {s.play_mean_ms / 1000:.0f} 秒前後"
              + "".join(f"\n    {i}" for i in errors + warns))
    print(f"\n{len(scenarios)} 人中 {len(scenarios) - n_ng} 人 OK。出力先: {args.out}")
    return 1 if n_ng else 0


if __name__ == "__main__":
    sys.exit(main())
