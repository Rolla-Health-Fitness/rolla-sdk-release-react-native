import { useEffect, useState } from 'react';
import { Button, StyleSheet, Text, View } from 'react-native';

import { Rolla, type RollaCloseEvent } from '@rolla-health/react-native-sdk';

export default function App() {
  const [version, setVersion] = useState<string>('?');
  const [lastClose, setLastClose] = useState<RollaCloseEvent | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    Rolla.getNativeSdkVersion()
      .then(setVersion)
      .catch(() => setVersion('unavailable'));

    const errorSub = Rolla.addListener('onError', (e) => {
      setError(`${e.code}: ${e.message}`);
    });
    return () => errorSub.remove();
  }, []);

  const onPress = async () => {
    setError(null);
    try {
      const close = await Rolla.show({
        token: 'replace-with-real-token',
        partnerId: 'replace-with-real-partner-id',
        environment: 'rnd',
      });
      setLastClose(close);
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    }
  };

  return (
    <View style={styles.container}>
      <Text style={styles.title}>Rolla SDK smoke test</Text>
      <Text>Native version: {version}</Text>
      <View style={styles.spacer} />
      <Button title="Open Rolla" onPress={onPress} />
      <View style={styles.spacer} />
      {lastClose && <Text>Last close: {lastClose.reason}</Text>}
      {error && <Text style={styles.error}>Error: {error}</Text>}
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    alignItems: 'center',
    justifyContent: 'center',
    padding: 16,
  },
  title: { fontSize: 18, fontWeight: '600', marginBottom: 12 },
  spacer: { height: 12 },
  error: { color: 'crimson', marginTop: 8 },
});
