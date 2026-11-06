"""課題アプリの「AirPods の記録テスト」(app_decisions #71) の記録を確かめる。
本番のセッションの被験者フォルダ (exp2_data/<ID>/、#72) を渡せば、その AirPods の記録も同じ物差しで見られる
(本番のデータの検証は validate_session.py が行う。こちらは受け取りの遅れなどを詳しく見るとき)。

    python3 tools/check_headphone_test.py <exp2_imu_test/IMUTEST_... または exp2_data/<ID> のフォルダ> [--figure <png>]
        [--compare <既存の IMU アプリの .db> [--compare-from "2026-11-05 14:00"] [--compare-to "2026-11-05 14:10"]]

表示するもの:
    - 何 Hz で取れたか (実験1の既存の IMU アプリは平均 50 Hz)
    - センサの時刻と受け取った時刻のそれぞれの空き (となりのサンプルとの差が gap_threshold_ms 以上の回数と最大)
    - 受け取った時刻が止まったところで、センサの時刻は続いていたか (続いていれば、センサの時刻を使えば止まりの影響を受けない)
    - 受け取りの遅れ、測っている側 (左右) の切り替わり、接続・切断などのイベント
    - --compare: 既存の IMU アプリで同じ動きを続けて記録したものと、Hz、空き、値の大きさを並べる
      (.db にはそれまでの記録がすべて入っているので、--compare-from / --compare-to で比べる時間を日本時間で絞る)

記録は読むだけで、変えない。
"""

import argparse
import sys
from pathlib import Path

import pandas as pd

sys.path.insert(0, str(Path(__file__).resolve().parent))

from exp2.headphone import compare_magnitudes, load_headphone_test, plot_test, summarize_imu_db, summarize_test  # noqa: E402
from exp2.load import load_imu_sqlite  # noqa: E402

TZ = "Asia/Tokyo"


def _to_unix_ms(text: str) -> int:
    return int(pd.Timestamp(text, tz=TZ).value // 1_000_000)


def _fmt(v, digits: int = 1) -> str:
    return "-" if v is None else f"{v:.{digits}f}"


def print_test_summary(s: dict) -> None:
    th = s["gap_threshold_ms"]
    print(f"== {s['test_id']}  ({s['n_samples']} サンプル)")
    if s["n_samples"] < 2:
        print("サンプルが2つ未満で、確かめられません")
        return
    print(f"長さ               {s['duration_min']:.1f} 分")
    print(f"平均               {s['mean_hz']:.2f} Hz  (1秒ごとのサンプル数: 最小 {s['per_second_min']}、中央値 {_fmt(s['per_second_median'])})")
    sg, rg = s["sensor_gap"], s["recv_gap"]
    print(f"センサの時刻の空き  最大 {sg['max_ms']:.0f} ms、{th} ms 以上 {sg['n_over']} 回")
    print(f"受け取った時刻の空き 最大 {rg['max_ms']:.0f} ms、{th} ms 以上 {rg['n_over']} 回"
          f" (うち、センサの時刻は続いていた {s['recv_stalls_sensor_continuous']} 回)")
    lat = s["latency_ms"]
    print(f"受け取りの遅れ      中央値 {lat['median']:.0f} ms、95% {lat['p95']:.0f} ms、最大 {lat['max']:.0f} ms")
    print(f"センサの時刻の逆行  {s['sensor_non_increasing']} 回")
    print(f"通し番号            {'0 から欠けずに続いている' if s['sample_index_ok'] else '欠けか重なりがある'}")
    print(f"測っている側        {s['location_counts']} (切り替わり {s['location_changes']} 回)")
    print(f"イベント            {s['event_counts']}")


def print_events(events: pd.DataFrame, t0_mono: float) -> None:
    shown = events[~events["event_type"].isin(["app_active", "app_inactive"])]
    if shown.empty:
        return
    print("\n-- イベント (最初のサンプルからの分)")
    for _, e in shown.iterrows():
        print(f"{(float(e['mono_ms']) - t0_mono) / 60_000:7.2f}  {e['event_type']:<20} {e['detail']}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("folder", type=Path, help="exp2_imu_test/IMUTEST_... または exp2_data/<ID> のフォルダ")
    parser.add_argument("--figure", type=Path, help="確認用の図を書く先 (.png、matplotlib が必要)")
    parser.add_argument("--compare", type=Path, help="比べる既存の IMU アプリの記録 (.db)")
    parser.add_argument("--compare-from", help="--compare で使う時間の始め (日本時間、例: '2026-11-05 14:00')")
    parser.add_argument("--compare-to", help="--compare で使う時間の終わり (日本時間)")
    args = parser.parse_args()

    t = load_headphone_test(args.folder)
    s = summarize_test(t)
    print_test_summary(s)
    if len(t.motion):
        print_events(t.events, float(t.motion["mono_ms"].min()))

    if args.compare:
        imu = load_imu_sqlite(args.compare)
        if args.compare_from:
            imu = imu[imu["unix_ms"] >= _to_unix_ms(args.compare_from)]
        if args.compare_to:
            imu = imu[imu["unix_ms"] < _to_unix_ms(args.compare_to)]
        b = summarize_imu_db(imu, t.gap_threshold_ms)
        print(f"\n== 既存の IMU アプリ {args.compare.name}  ({b['n_samples']} サンプル)")
        if b["n_samples"] < 2:
            print("比べる時間にサンプルがありません (--compare-from / --compare-to を確かめる)")
        else:
            rg = b["recv_gap"]
            print(f"長さ               {b['duration_min']:.1f} 分")
            print(f"平均               {b['mean_hz']:.2f} Hz")
            print(f"受け取った時刻の空き 最大 {rg['max_ms']:.0f} ms、{t.gap_threshold_ms} ms 以上 {rg['n_over']} 回")
            print(f"測っている側        {b['location_counts']}")
            if len(t.motion):
                print("\n-- 値の大きさ (app: 課題アプリ、imu_app: 既存の IMU アプリ。角度の p95 は絶対値)")
                with pd.option_context("display.float_format", "{:.4f}".format, "display.width", 120):
                    print(compare_magnitudes(t.motion, imu).to_string(index=False))

    if args.figure:
        if plot_test(t, args.figure):
            print(f"\n図: {args.figure}")
        else:
            print("\nmatplotlib がないので図は書きませんでした (requirements.txt にあります)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
