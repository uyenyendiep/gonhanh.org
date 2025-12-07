import SwiftUI

// MARK: - About View (Apple HIG Compliant)

struct AboutView: View {
    var body: some View {
        VStack(spacing: 16) {
            Spacer()
                .frame(height: 8)

            // Logo
            Image(nsImage: AppMetadata.logo)
                .resizable()
                .frame(width: 80, height: 80)

            // App Name
            Text(AppMetadata.name)
                .font(.system(size: 18, weight: .bold))

            // Version
            Text("Version \(AppMetadata.version) (\(AppMetadata.buildNumber))")
                .font(.callout)
                .foregroundStyle(.secondary)

            // Tagline
            Text(AppMetadata.tagline)
                .font(.callout)
                .foregroundStyle(.secondary)

            Spacer()
                .frame(height: 8)

            Divider()

            // Author
            VStack(spacing: 4) {
                Text("Developed by")
                    .font(.caption)
                    .foregroundStyle(.tertiary)

                Text(AppMetadata.author)
                    .font(.callout)
            }

            // Links
            HStack(spacing: 16) {
                Link(destination: URL(string: AppMetadata.website)!) {
                    Label("Website", systemImage: "globe")
                        .font(.callout)
                }

                Link(destination: URL(string: AppMetadata.repository)!) {
                    Label("GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
                        .font(.callout)
                }
            }
            .padding(.top, 4)

            Spacer()

            // Copyright
            Text(AppMetadata.copyright)
                .font(.caption2)
                .foregroundStyle(.tertiary)

            Spacer()
                .frame(height: 8)
        }
        .padding(.horizontal, 24)
        .frame(width: 300, height: 340)
    }
}

// MARK: - Preview

#Preview {
    AboutView()
}
