// A stand-in for `vscode-languageclient/node`, which needs the whole editor
// API at load time. Only so `src/extension.ts` can be loaded; no test starts
// a client.

export class LanguageClient {}
export class StreamMessageReader {}
export class StreamMessageWriter {}
export enum State {
  Stopped = 1,
  Starting = 3,
  Running = 2,
}
export enum RevealOutputChannelOn {
  Info = 1,
  Warn = 2,
  Error = 3,
  Never = 4,
}
export type ErrorHandler = unknown;
export type LanguageClientOptions = unknown;
export type ServerOptions = unknown;
export enum ErrorAction {
  Continue = 1,
  Shutdown = 2,
}
export enum CloseAction {
  DoNotRestart = 1,
  Restart = 2,
}
