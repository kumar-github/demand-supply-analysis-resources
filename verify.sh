#!/usr/bin/env bash
# Full verification for the frontend-anchor-flag fix.
# Run from the parent folder that contains both bench-match-cli/ and bench-match-webapp/.
set -euo pipefail

ROOT="$(pwd)"

echo "== 1/4: Python — regenerate classified CSVs + ground truth =="
cd "$ROOT/bench-match-cli"
python3 -c "import classify_inputs; classify_inputs.main()"
python3 build_matches.py
python3 write_shortlist_workbook.py
python3 export_full_ground_truth.py
# export_full_ground_truth.py drops its CSVs straight into this folder --
# no separate fixtures dir needed.

echo "== 2/4: Java — build classpath + compile everything the harnesses need =="
# cd "$ROOT/bench-match-webapp"
cd "$ROOT/app"
mvn -q dependency:build-classpath -Dmdep.outputFile=cp.txt
mkdir -p verify-out
# NOTE: deliberately NOT matching/*.java -- MatchingRunController.java and
# MatchingRunService.java need com.example.benchmatch.entity/repository,
# which none of these standalone harnesses use. Naming files explicitly.
javac -cp "$(cat cp.txt)" -d verify-out \
  src/main/java/com/example/benchmatch/matching/AssessmentResult.java \
  src/main/java/com/example/benchmatch/matching/ClassificationResult.java \
  src/main/java/com/example/benchmatch/matching/DemandClassifier.java \
  src/main/java/com/example/benchmatch/matching/Engine.java \
  src/main/java/com/example/benchmatch/matching/MatchRow.java \
  src/main/java/com/example/benchmatch/matching/MatchingService.java \
  src/main/java/com/example/benchmatch/matching/SignalResult.java \
  src/main/java/com/example/benchmatch/matching/SupplyClassifier.java \
  src/main/java/com/example/benchmatch/refresh/ExcelSheetReader.java \
  src/main/java/com/example/benchmatch/refresh/RefreshLogic.java \
  src/test/java/com/example/benchmatch/matching/MatchingRunVerification.java \
  src/test/java/com/example/benchmatch/refresh/RefreshLogicVerification.java

echo "== 3/4: RefreshLogicVerification (checks the NEW frontend-anchor flag) =="
java -cp "verify-out:$(cat cp.txt)" \
  com.example.benchmatch.refresh.RefreshLogicVerification \
  "$ROOT/bench-match-cli/input/AFD-Supply.xlsx" \
  "$ROOT/bench-match-cli/input/Demand.xlsx" \
  "$ROOT/bench-match-cli"

echo "== 4/4: MatchingRunVerification (checks match_candidates row parity) =="
java -cp "verify-out:$(cat cp.txt)" \
  com.example.benchmatch.matching.MatchingRunVerification \
  "$ROOT/bench-match-cli" \
  "$ROOT/bench-match-cli/data/match_rows.csv"

echo
echo "Done. Both harnesses above must print RESULT: PASS."
