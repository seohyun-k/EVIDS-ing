#!/usr/bin/env python3
"""A1 scope comparison + count-only ablation.

Reads the feature table from extract_features.py and evaluates the SAME decision
unit and labels under four observation scopes plus the count-only ablation, so any
performance difference is attributable to observation scope alone:

    ISO-only     iso_*                         single channel (EV side)
    OCPP-only    ocpp_*                        single channel (CSMS side)
    concat       iso_* + ocpp_*                both channels, no correspondence
    cross        iso_* + ocpp_* + cross_*      + ISO<->OCPP consistency (RV03/RV04)
    count-only   cnt_*                          ablation: is it just message volume?

The existence-proof reading: as the forgery factor shrinks toward the RV tolerance
edge, ISO-only / OCPP-only F1 should collapse toward chance while cross stays high,
AND count-only should NOT rescue it (the in-band spoof leaves counts unchanged).

Models: LogisticRegression (scaled), RandomForest, and XGBoost if installed.
CV: StratifiedKFold(K=5) over 3 seeds, metrics averaged across seeds.

Requires: scikit-learn, numpy. (pip install scikit-learn)  xgboost is optional.
"""
import argparse, csv, sys
import numpy as np
from sklearn.model_selection import StratifiedKFold, cross_val_predict
from sklearn.linear_model import LogisticRegression
from sklearn.ensemble import RandomForestClassifier
from sklearn.preprocessing import StandardScaler
from sklearn.pipeline import make_pipeline
from sklearn.metrics import precision_score, recall_score, f1_score, roc_auc_score

try:
    from xgboost import XGBClassifier
    HAVE_XGB = True
except Exception:
    HAVE_XGB = False

META_COLS = {"session_id", "label", "factor", "target"}
SCOPES = {
    "ISO-only":   lambda c: c.startswith("iso_"),
    "OCPP-only":  lambda c: c.startswith("ocpp_"),
    "concat":     lambda c: c.startswith(("iso_", "ocpp_")),
    "cross":      lambda c: c.startswith(("iso_", "ocpp_", "cross_")),
    "count-only": lambda c: c.startswith("cnt_"),
}


def load(path):
    with open(path) as f:
        rows = list(csv.DictReader(f))
    feat_cols = [c for c in rows[0] if c not in META_COLS]
    y = np.array([int(float(r["label"])) for r in rows])
    factor = np.array([float(r.get("factor", 1.0) or 1.0) for r in rows])
    def col(c):
        return np.array([float(r[c]) if r.get(c) not in (None, "") else 0.0 for r in rows])
    X = {c: col(c) for c in feat_cols}
    return X, y, factor, feat_cols


def matrix(X, cols):
    if not cols:
        return None
    return np.column_stack([X[c] for c in cols])


def models():
    m = {
        "LogReg": lambda: make_pipeline(
            StandardScaler(),
            LogisticRegression(class_weight="balanced", max_iter=2000, random_state=42)),
        "RF": lambda: RandomForestClassifier(
            n_estimators=300, class_weight="balanced", random_state=42),
    }
    if HAVE_XGB:
        m["XGB"] = lambda: XGBClassifier(
            random_state=42, eval_metric="logloss", n_estimators=300)
    return m


def eval_scope(Xm, y, seeds=(42, 7, 123)):
    """Average P/R/F1/AUROC over seeds using out-of-fold predictions."""
    if Xm is None or Xm.shape[1] == 0:
        return None
    out = {}
    for name, make in models().items():
        Ps, Rs, Fs, As = [], [], [], []
        for s in seeds:
            skf = StratifiedKFold(n_splits=5, shuffle=True, random_state=s)
            try:
                proba = cross_val_predict(make(), Xm, y, cv=skf, method="predict_proba")[:, 1]
            except Exception:
                proba = cross_val_predict(make(), Xm, y, cv=skf).astype(float)
            pred = (proba >= 0.5).astype(int)
            Ps.append(precision_score(y, pred, zero_division=0))
            Rs.append(recall_score(y, pred, zero_division=0))
            Fs.append(f1_score(y, pred, zero_division=0))
            As.append(roc_auc_score(y, proba) if len(set(y)) > 1 else float("nan"))
        out[name] = (np.mean(Ps), np.mean(Rs), np.mean(Fs), np.mean(As))
    return out


def run(X, y, feat_cols, label=""):
    print(f"\n=== A1 scope comparison {label}  (n={len(y)}, pos={int(y.sum())}, neg={int((1-y).sum())}) ===")
    print(f"{'scope':<11} {'model':<7} {'Prec':>6} {'Recall':>7} {'F1':>6} {'AUROC':>6}  #feat")
    for scope, sel in SCOPES.items():
        cols = [c for c in feat_cols if sel(c)]
        res = eval_scope(matrix(X, cols), y)
        if res is None:
            print(f"{scope:<11} (no features)")
            continue
        for mdl, (p, r, f, a) in res.items():
            print(f"{scope:<11} {mdl:<7} {p:6.3f} {r:7.3f} {f:6.3f} {a:6.3f}  {len(cols)}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--features", help="features.csv from extract_features.py")
    ap.add_argument("--by-factor", action="store_true",
                    help="also report ISO-only vs cross per intensity (existence-proof view)")
    ap.add_argument("--self-test", action="store_true",
                    help="synthesize data via extract_features --self-test, then evaluate")
    args = ap.parse_args()

    path = args.features
    if args.self_test:
        import os, subprocess
        here = os.path.dirname(os.path.abspath(__file__))
        subprocess.check_call([sys.executable, os.path.join(here, "extract_features.py"),
                               "--self-test", "--out", os.path.join(here, "features.csv")])
        path = os.path.join(here, "features_selftest.csv")
    if not path:
        ap.error("provide --features FILE or --self-test")

    X, y, factor, feat_cols = load(path)
    if len(set(y)) < 2:
        print("[eval] need both classes present", file=sys.stderr); sys.exit(2)
    run(X, y, feat_cols, label="(all sessions)")

    if args.by_factor:
        for fv in sorted(set(factor[y == 1])):
            mask = (y == 0) | (factor == fv)
            run({c: X[c][mask] for c in feat_cols}, y[mask], feat_cols,
                label=f"(normal + attack@factor={fv})")


if __name__ == "__main__":
    main()
