SPIKE := .build/release/gazespike
M0_DIR := recordings/m0

.PHONY: test spike m0-record m0-analyze

test:
	swift test

spike:
	swift build -c release --product gazespike

# M0: 60 s still + 60 s moving for each backend. Needs you in front of the camera.
m0-record: spike
	$(SPIKE) record --backend vision    --label still  --seconds 60 --countdown 5 --out $(M0_DIR)
	$(SPIKE) record --backend vision    --label moving --seconds 60 --countdown 5 --out $(M0_DIR)
	$(SPIKE) record --backend mediapipe --label still  --seconds 60 --countdown 5 --out $(M0_DIR)
	$(SPIKE) record --backend mediapipe --label moving --seconds 60 --countdown 5 --out $(M0_DIR)

m0-analyze: spike
	$(SPIKE) analyze $(M0_DIR)/*.jsonl
