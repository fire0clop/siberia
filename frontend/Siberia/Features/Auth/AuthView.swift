import SwiftUI

// MARK: – Aurora background (4 colour orbs in sinusoidal motion)

private struct AuroraBackground: View {
    let time: Double

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            ZStack {
                Color(red: 0.04, green: 0.03, blue: 0.12).ignoresSafeArea()

                orb(x: w*(0.28 + 0.24*sin(time*0.130)),        y: h*(0.28 + 0.20*cos(time*0.110)),
                    r: 530, c: Color(red: 0.24, green: 0.30, blue: 0.98))

                orb(x: w*(0.74 + 0.18*sin(time*0.095 + 1.2)),  y: h*(0.54 + 0.24*cos(time*0.160 + 2.1)),
                    r: 470, c: Color(red: 0.52, green: 0.13, blue: 0.90))

                orb(x: w*(0.62 + 0.28*cos(time*0.205 + 0.9)),  y: h*(0.18 + 0.14*sin(time*0.145 + 3.5)),
                    r: 350, c: Color(red: 0.03, green: 0.70, blue: 0.85))

                orb(x: w*(0.16 + 0.16*cos(time*0.165 + 4.2)),  y: h*(0.74 + 0.18*sin(time*0.125 + 1.8)),
                    r: 390, c: Color(red: 0.72, green: 0.15, blue: 0.80))
            }
        }
        .blur(radius: 52)
        .ignoresSafeArea()
    }

    private func orb(x: CGFloat, y: CGFloat, r: CGFloat, c: Color) -> some View {
        RadialGradient(colors: [c.opacity(0.68), .clear], center: .center,
                       startRadius: 0, endRadius: r / 2)
            .frame(width: r, height: r)
            .position(x: x, y: y)
            .blendMode(.screen)
    }
}

// MARK: – Floating star-dust particles (Canvas, CPU-light)

private struct StarField: View {
    let time: Double

    // 34 deterministic particles generated once
    private static let pts: [(x: Double, y: Double, sz: Double, spd: Double, ph: Double)] = {
        (0..<34).map { i in
            let a = Double(i) * 137.508   // golden-angle seed
            return (
                x:   (sin(a) * 0.5 + 0.5),
                y:   abs(fmod(cos(a * 1.618), 1.0)),
                sz:  1.1 + abs(fmod(sin(a * 2.4), 1.3)),
                spd: 0.014 + abs(fmod(sin(a * 0.71), 0.022)),
                ph:  a
            )
        }
    }()

    var body: some View {
        Canvas { ctx, size in
            for p in Self.pts {
                let y  = 1.0 - fmod(p.y + time * p.spd, 1.0)
                let x  = p.x + 0.045 * sin(time * 0.28 + p.ph)
                let op = 0.12 + 0.18 * abs(sin(time * 0.65 + p.ph))
                let s  = CGFloat(p.sz)
                ctx.fill(
                    Path(ellipseIn: CGRect(x: x*size.width - s/2,
                                          y: y*size.height - s/2,
                                          width: s, height: s)),
                    with: .color(.white.opacity(op))
                )
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

// MARK: – Glow text field

private struct GlowField: View {
    let icon: String
    let placeholder: String
    @Binding var text: String
    var isSecure = false
    var keyboard: UIKeyboardType = .default
    var contentType: UITextContentType? = nil

    @State private var focused = false
    @State private var reveal  = false
    @FocusState private var isFocused: Bool

    private let ac1 = Color(red: 0.44, green: 0.30, blue: 0.97)
    private let ac2 = Color(red: 0.03, green: 0.70, blue: 0.85)

    var body: some View {
        HStack(spacing: 13) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(
                    focused
                        ? AnyShapeStyle(LinearGradient(colors: [ac1, ac2],
                                                       startPoint: .topLeading,
                                                       endPoint: .bottomTrailing))
                        : AnyShapeStyle(Color.white.opacity(0.30))
                )
                .frame(width: 20)
                .animation(.easeInOut(duration: 0.20), value: focused)

            ZStack(alignment: .leading) {
                if text.isEmpty {
                    Text(placeholder)
                        .foregroundStyle(.white.opacity(0.26))
                        .font(.system(size: 15))
                        .allowsHitTesting(false)
                }
                Group {
                    if isSecure && !reveal {
                        SecureField("", text: $text)
                            .textContentType(contentType)
                    } else {
                        TextField("", text: $text)
                            .keyboardType(keyboard)
                            .textContentType(contentType)
                    }
                }
                .foregroundStyle(.white)
                .font(.system(size: 15))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .focused($isFocused)
                .onChange(of: isFocused) { _, v in
                    withAnimation(.easeInOut(duration: 0.22)) { focused = v }
                }
            }

            if isSecure {
                Button {
                    reveal.toggle()
                    UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                } label: {
                    Image(systemName: reveal ? "eye.slash" : "eye")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.30))
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 15)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.white.opacity(focused ? 0.08 : 0.04))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(
                            focused
                                ? LinearGradient(colors: [ac1, ac2],
                                                 startPoint: .leading, endPoint: .trailing)
                                : LinearGradient(colors: [.white.opacity(0.10), .white.opacity(0.05)],
                                                 startPoint: .leading, endPoint: .trailing),
                            lineWidth: focused ? 1.5 : 1
                        )
                }
                .shadow(color: focused ? ac1.opacity(0.50) : .clear, radius: 14)
        }
        .animation(.easeInOut(duration: 0.22), value: focused)
    }
}

// MARK: – Primary gradient button (shimmer sweep + press scale)

private struct PrimaryAuthButton: View {
    let label: String
    var isLoading = false
    let action: () -> Void

    @State private var pressing  = false
    @State private var shimPhase: CGFloat = -0.45

    private let c1 = Color(red: 0.44, green: 0.30, blue: 0.97)
    private let c2 = Color(red: 0.03, green: 0.70, blue: 0.85)

    var body: some View {
        Button {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            action()
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(LinearGradient(colors: [c1, c2], startPoint: .leading, endPoint: .trailing))

                // Perpetual shimmer sweep
                LinearGradient(
                    colors: [.clear, .white.opacity(0.22), .clear],
                    startPoint: UnitPoint(x: shimPhase - 0.32, y: 0),
                    endPoint:   UnitPoint(x: shimPhase + 0.32, y: 0)
                )
                .blendMode(.screen)
                .allowsHitTesting(false)

                Group {
                    if isLoading {
                        ProgressView().tint(.white)
                    } else {
                        Text(label)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .frame(height: 54)
            .scaleEffect(pressing ? 0.96 : 1)
            .shadow(color: c1.opacity(pressing ? 0.28 : 0.55),
                    radius: pressing ? 7 : 22, y: pressing ? 2 : 10)
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.13), value: pressing)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in pressing = true }
                .onEnded   { _ in pressing = false }
        )
        .onAppear {
            withAnimation(.linear(duration: 2.6).repeatForever(autoreverses: false)) {
                shimPhase = 1.45
            }
        }
    }
}

// MARK: – Ghost glass button

private struct GlassAuthButton: View {
    let label: String
    let action: () -> Void
    @State private var pressing = false

    var body: some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            action()
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.white.opacity(0.07))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(.white.opacity(0.14), lineWidth: 1)
                    )
                Text(label)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.82))
            }
            .frame(height: 54)
            .scaleEffect(pressing ? 0.96 : 1)
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.13), value: pressing)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in pressing = true }
                .onEnded   { _ in pressing = false }
        )
    }
}

// MARK: – Main view

struct AuthView: View {

    @StateObject private var vm = AuthViewModel()
    @EnvironmentObject var appState: AppState

    enum Mode: Equatable { case welcome, login, register }
    @State private var mode: Mode = .welcome

    // Entrance animation flags
    @State private var logoReady   = false
    @State private var taglineReady = false
    @State private var btnsReady   = false

    // Error shake
    @State private var shaking = false

    private let ac1 = Color(red: 0.44, green: 0.30, blue: 0.97)
    private let ac2 = Color(red: 0.03, green: 0.70, blue: 0.85)

    // MARK: – body

    var body: some View {
        TimelineView(.animation) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            ZStack {
                AuroraBackground(time: t)   // has its own .ignoresSafeArea()
                StarField(time: t)          // has its own .ignoresSafeArea()

                if mode == .welcome {
                    welcomeView
                        .transition(.opacity.combined(with: .scale(scale: 0.97)))
                } else {
                    formView
                }
            }
            .animation(.spring(response: 0.44, dampingFraction: 0.82), value: mode)
        }
        .onAppear {
            withAnimation(.spring(response: 0.68, dampingFraction: 0.68).delay(0.12)) { logoReady    = true }
            withAnimation(.easeOut(duration: 0.50).delay(0.58))                        { taglineReady = true }
            withAnimation(.spring(response: 0.55, dampingFraction: 0.80).delay(0.70)) { btnsReady    = true }
        }
        .onChange(of: vm.error) { _, e in
            guard e != nil else { return }
            shaking = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { shaking = false }
        }
        .sheet(isPresented: Binding(
            get: { vm.pendingTwoFactorToken != nil },
            set: { if !$0 { vm.cancelTwoFactor() } }
        )) {
            TwoFactorChallengeSheet(vm: vm)
        }
        .fullScreenCover(isPresented: $vm.pendingEmailVerification, onDismiss: {
            appState.setAuthenticatedAndBootstrap()
        }) {
            EmailVerificationView(email: vm.email)
        }
    }

    // MARK: – Welcome screen

    @ViewBuilder
    private var welcomeView: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 22) {
                // Logo circle
                logoMark(size: 106)
                    .scaleEffect(logoReady ? 1 : 0.52)
                    .opacity(logoReady ? 1 : 0)

                // Brand name + tagline
                VStack(spacing: 8) {
                    Text("SIBERIA")
                        .font(.system(size: 46, weight: .black, design: .rounded))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [.white, Color(red: 0.76, green: 0.70, blue: 1.0)],
                                startPoint: .top, endPoint: .bottom
                            )
                        )
                        .shadow(color: ac1.opacity(0.70), radius: 30)
                        .scaleEffect(logoReady ? 1 : 0.72)
                        .opacity(logoReady ? 1 : 0)

                    Text("связь без границ")
                        .font(.system(size: 14, weight: .regular))
                        .tracking(2.8)
                        .foregroundStyle(.white.opacity(0.32))
                        .opacity(taglineReady ? 1 : 0)
                }
            }

            Spacer()
            Spacer()

            // Action buttons
            VStack(spacing: 12) {
                PrimaryAuthButton(label: "Войти") {
                    vm.isLoginMode = true
                    withAnimation(.spring(response: 0.44, dampingFraction: 0.82)) { mode = .login }
                }
                GlassAuthButton(label: "Создать аккаунт") {
                    vm.isLoginMode = false
                    withAnimation(.spring(response: 0.44, dampingFraction: 0.82)) { mode = .register }
                }
            }
            .padding(.horizontal, 26)
            .padding(.bottom, 52)
            .offset(y: btnsReady ? 0 : 58)
            .opacity(btnsReady ? 1 : 0)
        }
    }

    // MARK: – Auth form (full-screen, fields in upper zone → keyboard can't cover them)

    @ViewBuilder
    private var formView: some View {
        let isLogin = (mode == .login)

        ZStack(alignment: .top) {
            // Extra dim so aurora stays atmospheric but form is readable
            Color.black.opacity(0.28).ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {

                    // ── Top bar ──────────────────────────────────────
                    HStack {
                        Button {
                            UIApplication.shared.sendAction(
                                #selector(UIResponder.resignFirstResponder),
                                to: nil, from: nil, for: nil
                            )
                            withAnimation(.spring(response: 0.44, dampingFraction: 0.82)) {
                                mode = .welcome
                            }
                        } label: {
                            ZStack {
                                Circle()
                                    .fill(.white.opacity(0.10))
                                    .overlay(Circle().stroke(.white.opacity(0.14), lineWidth: 1))
                                Image(systemName: "chevron.left")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(.white.opacity(0.80))
                            }
                            .frame(width: 38, height: 38)
                        }

                        Spacer()

                        logoMark(size: 36)
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 12)
                    .padding(.bottom, 32)

                    // ── Logo + title ─────────────────────────────────
                    VStack(spacing: 10) {
                        Text(isLogin ? "С возвращением" : "Новый аккаунт")
                            .font(.system(size: 30, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        Text(isLogin ? "Введи данные и поехали" : "Пара секунд — и ты внутри")
                            .font(.system(size: 15))
                            .foregroundStyle(.white.opacity(0.40))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal, 26)
                    .padding(.bottom, 28)

                    // ── Fields ───────────────────────────────────────
                    VStack(spacing: 12) {
                        GlowField(icon: "envelope", placeholder: "Email",
                                  text: $vm.email, keyboard: .emailAddress,
                                  contentType: .emailAddress)

                        if !isLogin {
                            GlowField(icon: "at", placeholder: "Никнейм",
                                      text: $vm.nickname,
                                      contentType: .username)
                                .transition(.scale(scale: 0.92, anchor: .top).combined(with: .opacity))
                        }

                        // .newPassword при регистрации → iOS предложит сохранить в Keychain
                        // .password    при входе       → iOS подставит сохранённые данные
                        GlowField(icon: "lock", placeholder: "Пароль",
                                  text: $vm.password, isSecure: true,
                                  contentType: isLogin ? .password : .newPassword)
                    }
                    .padding(.horizontal, 22)
                    .animation(.spring(response: 0.38, dampingFraction: 0.78), value: isLogin)

                    // ── Error ─────────────────────────────────────────
                    if let err = vm.error {
                        Label(err, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(Color(red: 1.0, green: 0.40, blue: 0.42))
                            .multilineTextAlignment(.center)
                            .padding(.top, 14)
                            .padding(.horizontal, 24)
                            .transition(.scale(scale: 0.88).combined(with: .opacity))
                            .offset(x: shaking ? 7 : 0)
                            .animation(
                                shaking
                                    ? .easeInOut(duration: 0.07).repeatCount(5, autoreverses: true)
                                    : .default,
                                value: shaking
                            )
                    }

                    // ── Submit ───────────────────────────────────────
                    PrimaryAuthButton(
                        label: isLogin ? "Войти" : "Зарегистрироваться",
                        isLoading: vm.isLoading
                    ) {
                        Task { await vm.submit(appState: appState) }
                    }
                    .padding(.horizontal, 22)
                    .padding(.top, 20)

                    // ── Switch login / register ───────────────────────
                    Button {
                        withAnimation(.spring(response: 0.38, dampingFraction: 0.80)) {
                            vm.error = nil
                            vm.isLoginMode = isLogin ? false : true
                            mode = isLogin ? .register : .login
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(isLogin ? "Нет аккаунта?" : "Уже есть аккаунт?")
                                .foregroundStyle(.white.opacity(0.38))
                            Text(isLogin ? "Создать" : "Войти")
                                .foregroundStyle(ac1)
                                .fontWeight(.semibold)
                        }
                        .font(.system(size: 14))
                    }
                    .padding(.top, 16)
                    .padding(.bottom, 40)
                }
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .transition(.opacity.combined(with: .scale(scale: 0.97)))
    }

    // MARK: – Logo mark helper

    private func logoMark(size: CGFloat) -> some View {
        ZStack {
            Circle()
                .fill(LinearGradient(colors: [ac1, ac2],
                                     startPoint: .topLeading,
                                     endPoint: .bottomTrailing))
                .frame(width: size, height: size)
                .shadow(color: ac1.opacity(0.58), radius: size * 0.30, y: size * 0.12)
                .overlay(Circle().stroke(.white.opacity(0.18), lineWidth: 1))

            Image(systemName: "snowflake")
                .font(.system(size: size * 0.44, weight: .ultraLight))
                .foregroundStyle(.white.opacity(0.92))
                .shadow(color: .white.opacity(0.30), radius: 6)
        }
    }
}

// MARK: – Placeholder helper (used by other views)

extension View {
    func placeholder<Content: View>(
        when shouldShow: Bool,
        alignment: Alignment = .leading,
        @ViewBuilder placeholder: () -> Content
    ) -> some View {
        ZStack(alignment: alignment) {
            placeholder().opacity(shouldShow ? 1 : 0)
            self
        }
    }
}
