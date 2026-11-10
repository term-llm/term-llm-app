import ComputerUseHelper

// Launched by LaunchServices as its own TCC principal, never a child Process.
HelperMain.run(executor: StubToolExecutor())
