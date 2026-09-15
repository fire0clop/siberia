// Core/UI/AsyncButton.swift
//
// Кнопка для async-действий с защитой от двойного нажатия.
//
// Проблема, которую решает: `Button { Task { await action() } }` с
// `.disabled(isBusy)` НЕ защищает от дабл-тапа — второй тап успевает
// заэнкьюить Task до того, как isBusy доедет до рендера. Здесь guard
// синхронный, на MainActor, до создания Task — второй тап отваливается
// гарантированно. Пока действие в полёте — спиннер и disabled.

import SwiftUI

struct AsyncButton<Label: View>: View {
	var role: ButtonRole? = nil
	let action: () async -> Void
	@ViewBuilder let label: () -> Label

	@State private var isRunning = false

	var body: some View {
		Button(role: role) {
			guard !isRunning else { return }
			isRunning = true
			Task {
				await action()
				isRunning = false
			}
		} label: {
			ZStack {
				label().opacity(isRunning ? 0.35 : 1)
				if isRunning {
					ProgressView().scaleEffect(0.8)
				}
			}
		}
		.disabled(isRunning)
	}
}

extension AsyncButton where Label == Text {
	init(_ title: String, role: ButtonRole? = nil, action: @escaping () async -> Void) {
		self.init(role: role, action: action) { Text(title) }
	}
}
