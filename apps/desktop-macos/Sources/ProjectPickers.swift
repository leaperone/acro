// 项目目录选择器与"新建终端"项目选择器。

import SwiftUI

struct ProjectDirectoryPicker: View {
    @ObservedObject var model: WorkbenchModel

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Button {
                        Task { await model.loadProjectDirectory(model.projectDirectoryHome) }
                    } label: {
                        Image(systemName: "house")
                    }
                    .disabled(model.projectDirectoryHome.isEmpty)
                    .help("主目录")
                    .accessibilityLabel("主目录")

                    Button {
                        Task { await model.loadProjectDirectory("/") }
                    } label: {
                        Image(systemName: "internaldrive")
                    }
                    .help("根目录")
                    .accessibilityLabel("根目录")

                    Button {
                        if let parent = model.projectDirectoryParent {
                            Task { await model.loadProjectDirectory(parent) }
                        }
                    } label: {
                        Image(systemName: "arrow.up")
                    }
                    .disabled(model.projectDirectoryParent == nil)
                    .help("上一级")
                    .accessibilityLabel("上一级")

                    TextField("路径", text: $model.projectPathInput)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit {
                            Task { await model.loadProjectDirectory(model.projectPathInput) }
                        }

                    Button {
                        Task { await model.loadProjectDirectory(model.projectPathInput) }
                    } label: {
                        Image(systemName: "arrow.right.circle")
                    }
                    .help("打开路径")
                    .accessibilityLabel("打开路径")
                }
                .padding(12)

                VStack(alignment: .leading, spacing: 4) {
                    Text("路径预览")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(model.projectPathPreview.isEmpty ? "正在读取…" : model.projectPathPreview)
                        .font(.callout.monospaced())
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.bottom, 10)

                Divider()

                if model.projectPickerLoading && model.projectDirectoryEntries.isEmpty {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(model.projectDirectoryEntries, id: \.path) { entry in
                            HStack(spacing: 8) {
                                Button {
                                    model.projectPathInput = entry.path
                                    model.projectPathPreview = entry.path
                                } label: {
                                    Label(entry.name, systemImage: "folder")
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)

                                Button {
                                    Task { await model.loadProjectDirectory(entry.path) }
                                } label: {
                                    Image(systemName: "chevron.right")
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                                .help("打开文件夹")
                                .accessibilityLabel("打开 \(entry.name)")
                            }
                            .listRowBackground(
                                model.projectPathPreview == entry.path
                                    ? Color.accentColor.opacity(0.12)
                                    : Color.clear
                            )
                        }
                    }
                    .overlay {
                        if model.projectDirectoryEntries.isEmpty && !model.projectPickerLoading {
                            ContentUnavailableView("没有子目录", systemImage: "folder")
                        }
                    }
                }
            }
            .navigationTitle("选择项目目录")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        model.projectPickerWorkspace = nil
                        model.resetProjectPicker()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("添加并打开终端") {
                        Task { await model.registerProjectAndOpenTerminal() }
                    }
                    .disabled(model.projectPathPreview.isEmpty || model.projectPickerLoading)
                }
            }
        }
        .frame(minWidth: 560, minHeight: 520)
        .onAppear {
            if model.projectDirectoryPath.isEmpty {
                Task { await model.loadProjectDirectory("~") }
            }
        }
    }
}

struct TerminalProjectPicker: View {
    @ObservedObject var model: WorkbenchModel

    var body: some View {
        NavigationStack {
            List {
                ForEach(model.filteredTerminalProjects) { project in
                    Button {
                        guard let workspace = model.terminalProjectPickerWorkspace else { return }
                        model.terminalProjectPickerWorkspace = nil
                        model.projectQuery = ""
                        Task { _ = await model.openTerminal(project: project, workspace: workspace) }
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Label(project.name, systemImage: "folder")
                            Text(project.path)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .searchable(text: $model.projectQuery, prompt: "搜索项目")
            .navigationTitle("新建终端")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        model.terminalProjectPickerWorkspace = nil
                        model.projectQuery = ""
                    }
                }
            }
        }
        .frame(minWidth: 460, minHeight: 420)
    }
}
