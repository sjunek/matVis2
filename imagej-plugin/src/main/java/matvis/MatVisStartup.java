package matvis;

import ij.plugin.PlugIn;

/**
 * Startup plugin — run automatically by Fiji via the AutoRun entry in
 * plugins.config when Fiji starts.
 *
 * Its sole job is to register the global Ctrl+M KeyEventDispatcher so that
 * MatVis can be launched with Ctrl+M even before the user has opened it
 * manually from the Plugins menu (which would normally let ImageJ's built-in
 * Analyze > Measure steal Ctrl+M first).
 */
public class MatVisStartup implements PlugIn {

    @Override
    public void run(String arg) {
        MatVisPlugin.installShortcut();
    }
}
