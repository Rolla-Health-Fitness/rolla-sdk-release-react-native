import { useEffect, useState } from 'react';
import { Text, View, StyleSheet, Pressable } from 'react-native';
import { Rolla } from '@rolla-health/react-native-sdk';

export default function App() {
  const [version, setVersion] = useState<string>('(loading…)');
  const [showStatus, setShowStatus] = useState<string>('idle');

  useEffect(() => {
    Rolla.getNativeSdkVersion()
      .then((v) => setVersion(v))
      .catch((e) => setVersion(`ERROR: ${e?.message ?? e}`));
  }, []);

  const onPress = async () => {
    try {
      setShowStatus('calling show()…');
      const closed = await Rolla.show({
        token: 'bogus-test-token',
        partnerId: 'demo',
        environment: 'rnd',
      });
      setShowStatus(`closed: ${closed.reason}`);
    } catch (e: any) {
      setShowStatus(`reject: ${e?.code ?? '?'} — ${e?.message ?? e}`);
    }
  };

  return (
    <View style={styles.container}>
      <Text style={styles.label}>@rolla-health/react-native-sdk</Text>
      <Text style={styles.result}>native version: {version}</Text>
      <Pressable style={styles.btn} onPress={onPress}>
        <Text style={styles.btnText}>Tap to call Rolla.show()</Text>
      </Pressable>
      <Text style={styles.status}>{showStatus}</Text>
      <Text style={styles.ok}>
        {version === '0.1.10' ? '✅ TURBO MODULE OK' : '⏳ awaiting native…'}
      </Text>
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    alignItems: 'center',
    justifyContent: 'center',
    backgroundColor: '#0f7a3a',
    padding: 24,
  },
  label: { color: 'white', fontSize: 14, marginBottom: 8 },
  result: {
    color: 'white',
    fontSize: 22,
    fontWeight: 'bold',
    marginBottom: 20,
  },
  btn: {
    backgroundColor: 'white',
    paddingHorizontal: 16,
    paddingVertical: 12,
    borderRadius: 8,
    marginBottom: 12,
  },
  btnText: { color: '#0f7a3a', fontWeight: 'bold' },
  status: { color: 'yellow', fontSize: 14, marginBottom: 16 },
  ok: { color: 'yellow', fontSize: 20, fontWeight: 'bold' },
});
