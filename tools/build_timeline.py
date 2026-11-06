"""課題アプリ (iPad) とゲームアプリ (iPhone) の記録を、被験者ごとに1本の時間軸に統合し、状態のラベルを書き出す。

    .venv/bin/python tools/build_timeline.py <exp2_data と exp2_game があるフォルダ> --out <出力先>
        [--game-root <exp2_game があるフォルダ>] [--imu-dir <ID>.db があるフォルダ] [--imu <ID>=<.db> ...]
        [--pairs <pairs.csv>] [--game-offset <ID>=<ms> ...] [--imu-offset <ID>=<ms> ...] [--figures] [--overwrite]

人ごとに <出力先>/<ID>/ に書く:
    events.csv       3つの記録の出来事を1本の時間軸に並べた表 (時刻は iPad の Unix 時刻 ms と、計算のみの区間の開始からの秒)
    intervals.csv    区間、ゲームの部分、iPhone を持っていた区間、長い回答の空き
    labels.csv       100 ms ごとの状態 (compute / game / neither / ambiguous。設計書7章)
    windows.csv      5秒窓・1秒ストライド。1つの状態にまるごと収まる窓だけに state が付く
    imu_states.csv   IMU の各サンプルに、iPad の時間軸の時刻と状態を付けたもの (IMU があるとき)。
                     課題アプリの AirPods の記録 (schema_version 4 から) なら sample_index、既存の IMU アプリなら ZDATA_LINES で行を示す
    timeline.png     確認用の図 (--figures、matplotlib が必要)
全員分は <出力先>/summary.csv (人ごとの指標) と <出力先>/params.json (使った閾値) と report.txt (警告)。

- 2台の記録の組は ID と記録の時間で決める。ID が食い違えば警告し、時間で組にする。手で決めるときは
  pairs.csv (列: task_id, game_id) を渡す
- --game-offset <ID>=<ms>: ゲームアプリの時刻に足す補正値 (iPhone の時計が 3 秒進んでいたら -3000)。
  警告に「補正値は … が合っていそう」と出たら、実験記録と合わせて確かめてから指定する
- 閾値は exp2/timeline.py の LabelParams。感度分析は Python から build_timeline(pair, params=...) を呼んで行う
- IMU は、被験者フォルダに AirPods の記録 (headphone_motion.csv) があればそれを使う (app_decisions #72)。
  --imu-dir、--imu、--imu-offset は、それより前の、既存の IMU アプリの記録 (.db) を使うときだけ
"""

import argparse
import json
import shutil
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import pandas as pd  # noqa: E402

from exp2.load import load_imu_sqlite  # noqa: E402
from exp2.timeline import LabelParams, Timeline, build_timeline, label_params_dict, pair_sessions  # noqa: E402
from exp2.validate import Issue  # noqa: E402


def parse_map(items, cast=int) -> dict:
    out = {}
    for item in items or []:
        key, _, value = item.partition("=")
        if not value:
            sys.exit(f"<ID>=<値> の形で指定してください: {item}")
        out[key] = cast(value)
    return out


def plot_timeline(tl: Timeline, labels: pd.DataFrame, imu: pd.DataFrame | None, path: Path) -> bool:
    """確認用の図。上から: 区間、状態、回答、iPhone を持っていた区間とゲームの部分、IMU の頭の前後の傾き。"""
    try:
        import matplotlib

        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
    except ImportError:
        return False
    colors = {"compute": "#4C78A8", "game": "#F58518", "neither": "#54A24B", "ambiguous": "#BBBBBB"}
    rows = 5 if imu is not None else 4
    fig, axes = plt.subplots(rows, 1, figsize=(16, 1.2 * rows + 1), sharex=True,
                             gridspec_kw={"height_ratios": [1, 1, 1, 1] + ([2] if imu is not None else [])})
    iv = tl.intervals_table()
    ax = axes[0]
    for _, r in iv[iv["kind"] == "segment"].iterrows():
        ax.axvspan(r["start_t_s"], r["end_t_s"], color="#DDDDDD")
        ax.text((r["start_t_s"] + r["end_t_s"]) / 2, 0.5, r["label"], ha="center", va="center", fontsize=8)
    ax.set_ylabel("segment")
    ax = axes[1]
    for state, color in colors.items():
        m = labels["state"] == state
        ax.scatter(labels.loc[m, "t_s"], [0.5] * int(m.sum()), s=4, marker="|", color=color, label=state)
    ax.legend(loc="upper right", ncol=4, fontsize=7, markerscale=3)
    ax.set_ylabel("state")
    ax = axes[2]
    ev = tl.events_table()
    ans = ev[ev["kind"] == "answer"]
    ax.scatter(ans["t_s"], [0.5] * len(ans), s=4, marker="|", color="#333333")
    ax.set_ylabel("answers")
    ax = axes[3]
    for _, r in iv[iv["kind"] == "holding"].iterrows():
        ax.axvspan(r["start_t_s"], r["end_t_s"], ymin=0.5, ymax=1, color=colors["game"])
    for _, r in iv[iv["kind"] == "game_part"].iterrows():
        ax.axvspan(r["start_t_s"], r["end_t_s"], ymin=0, ymax=0.45, color="#B279A2" if r["label"] == "stack" else "#9D755D")
    ax.set_ylabel("iPhone")
    if imu is not None:
        ax = axes[4]
        ax.plot(imu["t_s"], imu["pitch" if "pitch" in imu else "ZATT_PITCH"], lw=0.4, color="#333333")
        ax.set_ylabel("IMU pitch")
    for a in axes[:4]:
        a.set_yticks([])
    axes[-1].set_xlabel("t (s, focus start = 0)")
    fig.suptitle(f"{tl.participant_id} (iPhone: {tl.game_participant_id})")
    fig.tight_layout()
    fig.savefig(path, dpi=110)
    plt.close(fig)
    return True


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("root", type=Path)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--game-root", type=Path)
    parser.add_argument("--imu-dir", type=Path, help="<ID>.db が並んだフォルダ")
    parser.add_argument("--imu", nargs="*", help="<ID>=<.db のパス>")
    parser.add_argument("--pairs", type=Path, help="対応表 (列: task_id, game_id)")
    parser.add_argument("--game-offset", nargs="*", help="<ID>=<ms>: ゲームアプリの時刻に足す補正値")
    parser.add_argument("--imu-offset", nargs="*", help="<ID>=<ms>: IMU の時刻に足す補正値")
    parser.add_argument("--figures", action="store_true", help="確認用の図を書く (matplotlib が必要)")
    parser.add_argument("--overwrite", action="store_true", help="出力先に同じ ID のフォルダがあれば作り直す")
    args = parser.parse_args()

    overrides = {}
    if args.pairs:
        pt = pd.read_csv(args.pairs, dtype=str)
        overrides = dict(zip(pt["task_id"], pt["game_id"]))
    game_offsets = parse_map(args.game_offset)
    imu_offsets = parse_map(args.imu_offset)
    imu_paths = {k: Path(v) for k, v in parse_map(args.imu, cast=str).items()}

    params = LabelParams()
    pairs = pair_sessions(args.root, args.game_root, overrides, params)
    if not pairs:
        print(f"課題アプリの被験者フォルダが見つかりません: {args.root}", file=sys.stderr)
        return 1
    args.out.mkdir(parents=True, exist_ok=True)
    summaries, report = [], []
    figures_ok = True
    for pair in pairs:
        pid = pair.participant_id
        dest = args.out / pid
        if dest.exists():
            if not args.overwrite:
                print(f"{dest} が既にあります (--overwrite で作り直す)", file=sys.stderr)
                return 1
            shutil.rmtree(dest)
        dest.mkdir()
        tl = build_timeline(pair, params, game_offset_ms=game_offsets.get(pid, 0))
        labels = tl.labels()
        tl.events_table().to_csv(dest / "events.csv", index=False)
        tl.intervals_table().to_csv(dest / "intervals.csv", index=False)
        labels.to_csv(dest / "labels.csv", index=False)
        tl.windows(labels).to_csv(dest / "windows.csv", index=False)
        imu = None
        imu_path = imu_paths.get(pid) or (args.imu_dir / f"{pid}.db" if args.imu_dir else None)
        if tl.task.headphone is not None:
            # 課題アプリが記録した AirPods の動き (iPad の時計、センサの時刻)。初期化中の1サンプル (first_after_start) は印だけ付けて残す
            imu = tl.attach_imu(labels=labels)
            imu[["sample_index", "unix_ms", "task_unix_ms", "t_s", "segment", "state", "sensor_location",
                 "first_after_start"]].to_csv(dest / "imu_states.csv", index=False)
            if imu_path:
                tl.issues.append(Issue("WARN", "IMU", f"被験者フォルダの AirPods の記録を使い、{imu_path} は使いませんでした"))
        elif imu_path and imu_path.exists():
            imu = tl.attach_imu(load_imu_sqlite(imu_path), imu_offset_ms=imu_offsets.get(pid, 0), labels=labels)
            imu[["ZDATA_LINES", "unix_ms", "task_unix_ms", "t_s", "segment", "state"]].to_csv(
                dest / "imu_states.csv", index=False)
        elif imu_path:
            tl.issues.append(Issue("WARN", "IMU", f"{imu_path} がありません"))
        if args.figures and figures_ok:
            figures_ok = plot_timeline(tl, labels, imu, dest / "timeline.png")
        s = tl.summary(labels)
        s["n_warn"] = sum(i.level == "WARN" for i in tl.issues)
        s["n_error"] = sum(i.level == "ERROR" for i in tl.issues)
        summaries.append(s)
        lines = [f"== {pid} (iPhone: {pair.game_participant_id})"] + [f"  {i}" for i in tl.issues]
        report += lines
        print("\n".join(lines))
    pd.DataFrame(summaries).to_csv(args.out / "summary.csv", index=False)
    (args.out / "params.json").write_text(json.dumps(label_params_dict(params), ensure_ascii=False, indent=2))
    (args.out / "report.txt").write_text("\n".join(report) + "\n")
    if args.figures and not figures_ok:
        print("matplotlib がないので図は書きませんでした (requirements.txt にあります。入れてから --figures を付け直す)")
    n_err = sum(s["n_error"] > 0 for s in summaries)
    print(f"\n{len(summaries)} 人を統合しました (エラーあり {n_err} 人)。出力先: {args.out}")
    return 1 if n_err else 0


if __name__ == "__main__":
    sys.exit(main())
