import "./App.css";
import { Settings } from "./components/settings/Settings";
import HandyTextLogo from "./components/icons/HandyTextLogo";
import AccessibilityPermissions from "./components/AccessibilityPermissions";

function App() {
  return (
    <div className="min-h-screen flex flex-col items-center pt-6 w-full gap-4 px-4">
      <HandyTextLogo width={300} />
      <AccessibilityPermissions />
      <Settings />
    </div>
  );
}

export default App;
