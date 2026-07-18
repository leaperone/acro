import { registerRootComponent } from 'expo';
// Hermes 没有内建 crypto.getRandomValues,E2EE 密钥生成依赖它(expo-crypto 提供 polyfill)
import { getRandomValues } from 'expo-crypto';

import App from './App';

if (!globalThis.crypto?.getRandomValues) {
  // @ts-expect-error 最小 polyfill,只补 E2EE 用到的入口
  globalThis.crypto = { getRandomValues };
}

// registerRootComponent calls AppRegistry.registerComponent('main', () => App);
// It also ensures that whether you load the app in Expo Go or in a native build,
// the environment is set up appropriately
registerRootComponent(App);
