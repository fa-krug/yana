// Yana/Views/Components/SkeletonTimelineView.swift
import SwiftUI

/// Launch placeholder shown while the timeline is still resolving, so the cold-start frame
/// is a believable article shape instead of a blank or a wrong "No Articles" flash.
struct SkeletonTimelineView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            RoundedRectangle(cornerRadius: 12)
                .fill(.quaternary)
                .frame(height: 200)                       // lead image
            Text("Placeholder article headline goes here")  // headline
                .font(.title2.bold())
            Text("Feed name")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(0..<6, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 4).fill(.quaternary).frame(height: 12)
                }
            }
            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .skeleton(active: true)
        .background(Color(.systemBackground))
    }
}
