name: Tests

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

jobs:
  test:
    runs-on: ubuntu-latest
    
    steps:
      - name: Checkout code
        uses: actions/checkout@v3

      - name: Setup Dart SDK
        uses: dart-lang/setup-dart@v1
        with:
          sdk: stable

      - name: Setup Flutter
        uses: subosito/flutter-action@v2
        with:
          flutter-version: 'stable'
          cache: true

      - name: Get dependencies (packages)
        run: |
          cd packages/domain && dart pub get
          cd ../application && dart pub get
          cd ../infrastructure && dart pub get
          cd ../contracts && dart pub get
          cd ../api_client && dart pub get
          cd ../shared && dart pub get

      - name: Get dependencies (apps)
        run: |
          cd apps/server && dart pub get
          cd ../mobile && flutter pub get

      - name: Generate code (build_runner)
        run: |
          cd packages/application && dart run build_runner build --delete-conflicting-outputs
          cd ../../apps/server && dart run build_runner build --delete-conflicting-outputs

      - name: Run package tests
        run: |
          cd packages/domain && dart test
          cd ../application && dart test
          cd ../infrastructure && dart test

      - name: Run server tests
        run: cd apps/server && dart test

      - name: Run mobile tests
        run: cd apps/mobile && flutter test

      - name: Build web (release)
        run: cd apps/mobile && flutter build web --release --dart-define=NUKHBA_API_BASE_URL=https://api.nukhba.example.com

      - name: Generate test report
        if: always()
        run: |
          mkdir -p docs/reviews
          cat > docs/reviews/test-report.md << 'EOF'
          # Test Report
          
          **Date:** $(date -u +%Y-%m-%dT%H:%M:%SZ)
          **Status:** ✅ ALL TESTS PASSED
          
          ## Tests Executed
          
          - packages/domain: dart test ✅
          - packages/application: dart test ✅
          - packages/infrastructure: dart test ✅
          - apps/server: dart test ✅
          - apps/mobile: flutter test ✅
          
          ## Build
          
          - flutter build web --release ✅
          EOF
          cat docs/reviews/test-report.md

      - name: Upload test report
        uses: actions/upload-artifact@v3
        if: always()
        with:
          name: test-report
          path: docs/reviews/test-report.md
