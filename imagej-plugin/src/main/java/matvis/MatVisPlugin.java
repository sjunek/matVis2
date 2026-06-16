package matvis;

import ij.IJ;
import ij.ImagePlus;
import ij.plugin.PlugIn;
import matvis.ui.MatVisFrame;

import javax.swing.*;
import javax.swing.text.JTextComponent;
import java.awt.*;
import java.awt.event.KeyEvent;
import java.awt.KeyEventDispatcher;

/**
 * ImageJ/Fiji plugin entry point.
 *
 * Install by placing the compiled JAR in Fiji's plugins/ folder.
 * Run via:  Plugins ▶ MatVis ▶ Navigate...   or press Ctrl+M.
 *
 * On first run a global KeyEventDispatcher is registered so that Ctrl+M
 * launches MatVis from anywhere in Fiji (even when focus is on an ImageJ
 * window that has its own Ctrl+M = Measure binding).  The dispatcher is
 * installed only once per JVM session and only fires when the focused
 * component is NOT a text field (to avoid hijacking text editing).
 */
public class MatVisPlugin implements PlugIn {

    /** Installed at most once for the lifetime of the Fiji JVM. */
    private static volatile boolean shortcutInstalled = false;

    @Override
    public void run(String arg) {
        installShortcut();   // no-op after first call

        // When triggered via keyboard the image might have been passed in arg
        // by a future caller; for now we always use the active image.
        openOnActiveImage();
    }

    // ---- shortcut registration ---------------------------------------------

    /** Public so MatVisStartup can call it at Fiji startup. */
    public static void installShortcut() {
        if (shortcutInstalled) return;
        shortcutInstalled = true;

        KeyboardFocusManager.getCurrentKeyboardFocusManager()
                .addKeyEventDispatcher(new KeyEventDispatcher() {
                    public boolean dispatchKeyEvent(KeyEvent e) {
                        // Only act on KEY_PRESSED, Ctrl+M, no other modifiers
                        if (e.getID()       != KeyEvent.KEY_PRESSED)  return false;
                        if (e.getKeyCode()  != KeyEvent.VK_M)         return false;
                        if (!e.isControlDown())                        return false;
                        if (e.isShiftDown() || e.isAltDown())         return false;

                        // Don't hijack Ctrl+M while the user is typing in a text field
                        Component focused = KeyboardFocusManager
                                .getCurrentKeyboardFocusManager().getFocusOwner();
                        if (focused instanceof JTextComponent) return false;
                        if (focused instanceof java.awt.TextComponent) return false;

                        e.consume();
                        SwingUtilities.invokeLater(() -> openOnActiveImage());
                        return true;
                    }
                });
    }

    // ---- core logic --------------------------------------------------------

    private static void openOnActiveImage() {
        ImagePlus imp = IJ.getImage();
        if (imp == null) {
            IJ.error("MatVis", "No image is open. Please open an image first.");
            return;
        }
        final ImagePlus finalImp = imp;
        SwingUtilities.invokeLater(() -> {
            try {
                UIManager.setLookAndFeel(UIManager.getSystemLookAndFeelClassName());
            } catch (Exception ignored) {}

            MatVisController controller = new MatVisController(finalImp);
            MatVisFrame frame = new MatVisFrame(controller);
            frame.setVisible(true);
        });
    }
}
