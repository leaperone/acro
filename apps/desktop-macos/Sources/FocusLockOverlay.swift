import SwiftUI

struct FocusLockOverlay: View {
    let deviceName: String
    let takeOver: () -> Void

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.regularMaterial)
            VStack(spacing: 10) {
                Image(systemName: "display.2")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text("此终端正在被「\(deviceName)」使用")
                    .font(.callout.weight(.semibold))
                Text("接管后这里恢复操作,对方会被暂停并需要重新接管")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("在此设备继续使用", action: takeOver)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
            }
            .padding(24)
        }
        .contentShape(Rectangle())
    }
}
