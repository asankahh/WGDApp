import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:local_auth/local_auth.dart';
import 'package:google_fonts/google_fonts.dart';

// --- MAIN ENTRY POINT ---
void main() {
  runApp(const ProviderScope(child: WGDashboardApp()));
}

// --- THEME & APP SETUP ---
class WGDashboardApp extends StatelessWidget {
  const WGDashboardApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'WG Manager',
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.teal, 
          brightness: Brightness.light
        ),
        textTheme: GoogleFonts.interTextTheme(),
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.teal, 
          brightness: Brightness.dark
        ),
        textTheme: GoogleFonts.interTextTheme(ThemeData.dark().textTheme),
      ),
      themeMode: ThemeMode.system,
      home: const AuthCheckScreen(),
    );
  }
}

// --- STATE MANAGEMENT (PROVIDERS) ---
final storageProvider = Provider((ref) => const FlutterSecureStorage());
final dioProvider = Provider((ref) => Dio());

// Store Host URL and API Key
final authProvider = StateNotifierProvider<AuthNotifier, AuthState>((ref) {
  return AuthNotifier(ref.read(storageProvider));
});

class AuthState {
  final bool isAuthenticated;
  final String? host;
  final String? apiKey;
  AuthState({this.isAuthenticated = false, this.host, this.apiKey});
}

class AuthNotifier extends StateNotifier<AuthState> {
  final FlutterSecureStorage _storage;
  final LocalAuthentication auth = LocalAuthentication();

  AuthNotifier(this._storage) : super(AuthState()) {
    _checkSavedSession();
  }

  Future<void> _checkSavedSession() async {
    final host = await _storage.read(key: 'wg_host');
    final key = await _storage.read(key: 'wg_key');
    
    if (host != null && key != null) {
      // Prompt Biometric
      bool didAuthenticate = false;
      try {
        didAuthenticate = await auth.authenticate(
          localizedReason: 'Please authenticate to access WireGuard',
          options: const AuthenticationOptions(biometricOnly: false),
        );
      } catch (e) {
        // Handle no hardware cases gracefully
      }

      if (didAuthenticate) {
        state = AuthState(isAuthenticated: true, host: host, apiKey: key);
      }
    }
  }

  Future<void> login(String host, String key) async {
    await _storage.write(key: 'wg_host', value: host);
    await _storage.write(key: 'wg_key', value: key);
    state = AuthState(isAuthenticated: true, host: host, apiKey: key);
  }
  
  Future<void> logout() async {
     state = AuthState(isAuthenticated: false);
     // Optional: clear storage if you want to force re-entry
  }
}

// API Data Provider
final dashboardDataProvider = FutureProvider<List<dynamic>>((ref) async {
  final auth = ref.watch(authProvider);
  final dio = ref.watch(dioProvider);

  if (auth.host == null || auth.apiKey == null) return [];

  // Construct URL carefully (remove trailing slash if exists)
  final cleanHost = auth.host!.endsWith('/') 
      ? auth.host!.substring(0, auth.host!.length - 1) 
      : auth.host;

  try {
    final response = await dio.get(
      '$cleanHost/api/getWireguardConfigurations',
      options: Options(headers: {
        'Content-Type': 'application/json',
        'wg-dashboard-apikey': auth.apiKey
      }),
    );
    return response.data['data'];
  } catch (e) {
    throw Exception('Failed to load dashboard: $e');
  }
});

// --- UI SCREENS ---

// 1. Auth Check / Login Wrapper
class AuthCheckScreen extends ConsumerWidget {
  const AuthCheckScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final authState = ref.watch(authProvider);

    if (authState.isAuthenticated) {
      return const DashboardScreen();
    }
    return const LoginScreen();
  }
}

// 2. Login Screen
class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});
  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _hostController = TextEditingController(text: "https://");
  final _keyController = TextEditingController();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.security, size: 64, color: Colors.teal),
              const SizedBox(height: 24),
              Text("Connect to Dashboard", style: Theme.of(context).textTheme.headlineMedium),
              const SizedBox(height: 32),
              TextField(
                controller: _hostController,
                decoration: const InputDecoration(
                  labelText: "Host URL",
                  border: OutlineInputBorder(),
                  hintText: "https://vpn.example.com"
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _keyController,
                decoration: const InputDecoration(
                  labelText: "API Key",
                  border: OutlineInputBorder(),
                ),
                obscureText: true,
              ),
              const SizedBox(height: 24),
              FilledButton.icon(
                onPressed: () {
                  ref.read(authProvider.notifier).login(
                    _hostController.text.trim(), 
                    _keyController.text.trim()
                  );
                },
                icon: const Icon(Icons.login),
                label: const Text("Save & Connect"),
              )
            ],
          ),
        ),
      ),
    );
  }
}

// 3. Dashboard Screen (The Main View)
class DashboardScreen extends ConsumerWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final asyncData = ref.watch(dashboardDataProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text("WireGuard Manager"),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () => ref.refresh(dashboardDataProvider),
          ),
          IconButton(
            icon: const Icon(Icons.logout),
            onPressed: () => ref.read(authProvider.notifier).logout(),
          )
        ],
      ),
      body: asyncData.when(
        data: (configs) => ListView.builder(
          padding: const EdgeInsets.all(16),
          itemCount: configs.length,
          itemBuilder: (context, index) {
            final config = configs[index];
            final name = config['Name'];
            final address = config['Address'];
            final port = config['ListenPort'];
            // Simplify status check (assuming boolean or string)
            final bool isUp = config['Status'] == true || config['Status'] == 'true'; 

            return Card(
              elevation: 2,
              margin: const EdgeInsets.only(bottom: 16),
              child: ListTile(
                leading: CircleAvatar(
                  backgroundColor: isUp ? Colors.green.shade100 : Colors.red.shade100,
                  child: Icon(
                    isUp ? Icons.check : Icons.power_settings_new,
                    color: isUp ? Colors.green.shade800 : Colors.red.shade800,
                  ),
                ),
                title: Text(name, style: const TextStyle(fontWeight: FontWeight.bold)),
                subtitle: Text("$address :$port"),
                trailing: const Icon(Icons.chevron_right),
                onTap: () {
                  // Todo: Navigate to Peer Detail
                },
              ),
            );
          },
        ),
        error: (err, stack) => Center(child: Text("Error: $err")),
        loading: () => const Center(child: CircularProgressIndicator()),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () {},
        child: const Icon(Icons.add),
      ),
    );
  }
}