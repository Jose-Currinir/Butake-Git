import SwiftUI

/// Shown only when the Mac has no Git: what is missing, one button to install it, and it closes by itself.
struct GitRequirementSheet: View {
    @Bindable var requirement: GitRequirement
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "arrow.triangle.branch").font(.system(size: 26, weight: .semibold)).foregroundStyle(Brand.accent)
                    .frame(width: 48, height: 48).background(Brand.accent.opacity(0.13), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(L("gitMissingTitle")).font(.ui(size: 17, weight: .semibold))
                    Text(L("gitMissingDetail")).font(.uiCallout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            if requirement.state == .installing {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(L("gitMissingWaiting")).font(.uiCallout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Text(L("gitMissingHomebrew")).font(.uiCaption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(L("gitMissingRetry")) { Task { await requirement.check() } }.accessibilityIdentifier("gitMissing.retry")
                Spacer()
                Button(L("gitMissingInstall")) { requirement.installAppleTools() }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(requirement.state == .installing).accessibilityIdentifier("gitMissing.install")
            }
        }
        .padding(22)
        .frame(width: 480)
        .interactiveDismissDisabled()
    }
}
