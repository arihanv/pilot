import SwiftUI
import UIKit

// MARK: - Tap-capture UIKit overlay

private struct TapCaptureView: UIViewRepresentable {
    let onTap: (CGPoint) -> Void

    func makeUIView(context: Context) -> TapCaptureUIView {
        let v = TapCaptureUIView()
        v.onTap = onTap
        v.backgroundColor = .clear
        return v
    }
    func updateUIView(_ view: TapCaptureUIView, context: Context) {
        view.onTap = onTap
    }
}

private class TapCaptureUIView: UIView {
    var onTap: ((CGPoint) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        tap.cancelsTouchesInView = false
        addGestureRecognizer(tap)
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func tapped(_ g: UITapGestureRecognizer) {
        onTap?(g.location(in: self))
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesBegan(touches, with: event)
        if let t = touches.first { onTap?(t.location(in: self)) }
    }
}

// MARK: - CalibrationView

struct CalibrationView: View {
    @Bindable var manager: LiveModeManager
    @Environment(\.dismiss) private var dismiss

    enum Phase: Equatable {
        case ready
        case verifying
        case done
        case failed(String)
    }

    @State private var phase: Phase = .ready
    @State private var statusText = "Tap Start to begin calibration."
    @State private var result: CalibrationData?
    @State private var verifyError: Double?

    @State private var lastTapPoint: CGPoint?
    @State private var lastTapTime: Date = .distantPast

    private var isCapturingTaps: Bool {
        switch phase {
        case .verifying: return true
        default: return false
        }
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 24) {
                Spacer()
                progressRing

                Text(statusText)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)


                if let verifyError {
                    Text(String(format: "Verification error: %.1f pt", verifyError))
                        .font(.footnote.monospaced())
                        .foregroundStyle(verifyError < 15 ? .green : .orange)
                }

                if let result {
                    calibrationResultCard(result)
                }

                Spacer()
                buttons.padding(.bottom, 30)
            }
            .padding(.horizontal, 24)
            .allowsHitTesting(!isCapturingTaps)

            if isCapturingTaps {
                TapCaptureView { pt in
                    lastTapPoint = pt
                    lastTapTime = Date()
                }
                .ignoresSafeArea()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
    }

    // MARK: Sub-views

    @ViewBuilder
    private var progressRing: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.1), lineWidth: 4)
                .frame(width: 80, height: 80)

            switch phase {
            case .verifying:
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(.blue)
                    .scaleEffect(1.4)
            case .done:
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.green)
            case .failed:
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.red)
            case .ready:
                Image(systemName: "scope")
                    .font(.system(size: 40))
                    .foregroundStyle(.blue)
            }
        }
    }

    @ViewBuilder
    private var buttons: some View {
        switch phase {
        case .ready:
            Button {
                Task { await runCalibration() }
            } label: {
                Label("Start Calibration", systemImage: "scope")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 50)
            }
            .buttonStyle(.borderedProminent)

            Button("Cancel") { dismiss() }
                .foregroundStyle(.white.opacity(0.6))

        case .done:
            Button {
                result?.save()
                dismiss()
            } label: {
                Label("Save & Close", systemImage: "checkmark")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 50)
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)

            Button("Recalibrate") { resetState() }
                .foregroundStyle(.white.opacity(0.6))

        case .failed:
            Button("Retry") {
                resetState()
                Task { await runCalibration() }
            }
            .buttonStyle(.borderedProminent)

            Button("Cancel") { dismiss() }
                .foregroundStyle(.white.opacity(0.6))

        default:
            Text("Do not touch the screen")
                .font(.caption)
                .foregroundStyle(.yellow)
        }
    }

    private func calibrationResultCard(_ cal: CalibrationData) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Calibration Results")
                .font(.caption.weight(.bold))
                .foregroundStyle(.white.opacity(0.7))
            Group {
                Text("Screen: \(Int(cal.screenWidthPt))×\(Int(cal.screenHeightPt)) pt @ \(Int(cal.retinaScale))x")
                Text("Absolute hardware mapping enabled.")
            }
            .font(.caption.monospaced())
            .foregroundStyle(.white.opacity(0.8))
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: - Calibration logic

    private func resetState() {
        phase = .ready
        statusText = "Tap Start to begin calibration."
        result = nil
        verifyError = nil
        lastTapPoint = nil
    }

    private func runCalibration() async {
        let bounds = UIScreen.main.bounds
        let scale = UIScreen.main.scale
        let screenW = bounds.width
        let screenH = bounds.height

        do {
            _ = try await manager.sendCalibrationCommand("SET_SCREEN \(Int(screenW)) \(Int(screenH))")
        } catch {
            fail("SET_SCREEN failed: \(error.localizedDescription)")
            return
        }

        let cal = CalibrationData(
            screenWidthPt: screenW,
            screenHeightPt: screenH,
            retinaScale: scale,
            date: Date()
        )
        result = cal

        phase = .verifying
        statusText = "Verifying absolute targeting..."

        let centerPt = CGPoint(x: screenW / 2, y: screenH / 2)

        lastTapPoint = nil
        let before = Date()
        do {
            _ = try await manager.sendCalibrationCommand(
                "TAP \(Int(centerPt.x)) \(Int(centerPt.y))", timeout: 15)
        } catch {
            phase = .done
            statusText = "Calibration complete! (verification skipped)"
            return
        }

        if let vTap = await waitForFreshTap(after: before, timeout: 5) {
            let dx = vTap.x - centerPt.x
            let dy = vTap.y - centerPt.y
            verifyError = sqrt(dx * dx + dy * dy)
        }

        phase = .done
        statusText = "Calibration complete!"
    }

    private func fail(_ msg: String) {
        phase = .failed(msg)
        statusText = msg
    }

    // MARK: - BLE helpers

    private func waitForFreshTap(after date: Date, timeout: TimeInterval) async -> CGPoint? {
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            if let tap = lastTapPoint, lastTapTime > date {
                return tap
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return nil
    }

}
