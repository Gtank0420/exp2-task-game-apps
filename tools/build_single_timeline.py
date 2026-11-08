"""1台版の記録を、被験者ごとに1本の時間軸に並べ、状態のラベルと5秒窓を書き出す。

    .venv/bin/python tools/build_single_timeline.py <exp2_single、またはその親> --out <出力先> [--figures] [--overwrite]

人ごとに <出力先>/<ID>/ に書く (2台版の tools/build_timeline.py と同じ形):
    events.csv       出来事 (events.csv の出来事、回答、タッチ) を1本の時間軸に並べた表
    intervals.csv    区間、ポップアップ、ゲームの部分、長い回答の空き
    labels.csv       100 ms ごとの状態 (compute / game / game_idle / onset / dismissed / neither / ambiguous。設計書7章)。
                     ポップアップの番号と、出てからの時間 (since_shown_ms、設計書8.2) も付く
    windows.csv      5秒窓・1秒ストライド。1つの状態にまるごと収まる窓だけに state が付く
    imu_states.csv   AirPods の各サンプルに状態を付けたもの (AirPods の記録があるとき)
    timeline.png     確認用の図 (--figures、matplotlib が必要)
全員分は <出力先>/summary.csv (人ごとの指標)、params.json (使った閾値)、report.txt (警告)。

- 時計は iPad の1つだけなので、2台版のような組み合わせと時計の補正はない
- 閾値は exp2/single_timeline.py の SingleLabelParams。感度分析は Python から build_single_timeline(folder, params=...) で行う
"""

import argparse
import json
import shutil
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import pandas as pd  # noqa: E402

from exp2.single_load import single_session_folders  # noqa: E402
from exp2.single_timeline import (  # noqa: E402
    SingleLabelParams,
    SingleTimeline,
    build_single_timeline,
    single_label_params_dict,
)

COLORS = {"compute": "#4C78A8", "game": "#F58518", "game_idle": "#FFBF79", "onset": "#B279A2",
          "dismissed": "#9D755D", "neither": "#54A24B", "ambiguous": "#BBBBBB"}


def plot_timeline(tl: SingleTimeline, labels: pd.DataFrame, imu: pd.DataFrame | None, path: Path) -> bool:
    """確認用の図。上から: 区間、状態、回答、ポップアップとゲームの操作、IMU の頭の前後の傾き。"""
    try:
        import matplotlib

        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
    except ImportError:
        return False
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
    for state, color in COLORS.items():
        m = labels["state"] == state
        if m.any():
            ax.scatter(labels.loc[m, "t_s"], [0.5] * int(m.sum()), s=4, marker="|", color=color, label=state)
    ax.legend(loc="upper right", ncol=7, fontsize=7, markerscale=3)
    ax.set_ylabel("state")
    ax = axes[2]
    ev = tl.events_table()
    ans = ev[ev["kind"] == "answer"]
    ax.scatter(ans["t_s"], [0.5] * len(ans), s=4, marker="|", color="#333333")
    ax.set_ylabel("answers")
    ax = axes[3]
    for _, r in iv[iv["kind"] == "popup"].iterrows():
        ax.axvspan(r["start_t_s"], r["end_t_s"], ymin=0.5, ymax=1, color=COLORS["game"])
    act = tl.game_actions()
    ax.scatter(tl._t_s(act["unix_ms"]), [0.25] * len(act), s=4, marker="|", color="#333333")
    ax.set_ylabel("popup / actions")
    if imu is not None:
        ax = axes[4]
        ax.plot(imu["t_s"], imu["pitch"], lw=0.4, color="#333333")
        ax.set_ylabel("IMU pitch")
    for a in axes[:4]:
        a.set_yticks([])
    axes[-1].set_xlabel("t (s, focus start = 0)")
    fig.suptitle(tl.participant_id)
    fig.tight_layout()
    fig.savefig(path, dpi=110)
    plt.close(fig)
    return True


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("root", type=Path)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--figures", action="store_true", help="確認用の図を書く (matplotlib が必要)")
    parser.add_argument("--overwrite", action="store_true", help="出力先に同じ ID のフォルダがあれば作り直す")
    args = parser.parse_args()

    folders = single_session_folders(args.root)
    if not folders:
        print(f"1台版の被験者フォルダが見つかりません: {args.root}", file=sys.stderr)
        return 1
    params = SingleLabelParams()
    args.out.mkdir(parents=True, exist_ok=True)
    summaries, report = [], []
    figures_ok = True
    for folder in folders:
        pid = folder.name
        dest = args.out / pid
        if dest.exists():
            if not args.overwrite:
                print(f"{dest} が既にあります (--overwrite で作り直す)", file=sys.stderr)
                return 1
            shutil.rmtree(dest)
        dest.mkdir()
        tl = build_single_timeline(folder, params)
        labels = tl.labels()
        tl.events_table().to_csv(dest / "events.csv", index=False)
        tl.intervals_table().to_csv(dest / "intervals.csv", index=False)
        labels.to_csv(dest / "labels.csv", index=False)
        tl.windows(labels).to_csv(dest / "windows.csv", index=False)
        imu = tl.attach_imu(labels=labels)
        if imu is not None:
            # 初期化中の1サンプル (first_after_start) は印だけ付けて残す (2台版と同じ)
            imu[["sample_index", "unix_ms", "t_s", "segment", "state", "popup_index", "sensor_location",
                 "first_after_start"]].to_csv(dest / "imu_states.csv", index=False)
        if args.figures and figures_ok:
            figures_ok = plot_timeline(tl, labels, imu, dest / "timeline.png")
        s = tl.summary(labels)
        s["n_warn"] = sum(i.level == "WARN" for i in tl.issues)
        s["n_error"] = sum(i.level == "ERROR" for i in tl.issues)
        summaries.append(s)
        lines = [f"== {pid}"] + [f"  {i}" for i in tl.issues]
        report += lines
        print("\n".join(lines))
    pd.DataFrame(summaries).to_csv(args.out / "summary.csv", index=False)
    (args.out / "params.json").write_text(json.dumps(single_label_params_dict(params), ensure_ascii=False, indent=2))
    (args.out / "report.txt").write_text("\n".join(report) + "\n")
    if args.figures and not figures_ok:
        print("matplotlib がないので図は書きませんでした (requirements.txt にあります。入れてから --figures を付け直す)")
    n_err = sum(s["n_error"] > 0 for s in summaries)
    print(f"\n{len(summaries)} 人を統合しました (エラーあり {n_err} 人)。出力先: {args.out}")
    return 1 if n_err else 0


if __name__ == "__main__":
    sys.exit(main())
