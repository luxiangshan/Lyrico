package com.lonx.lyrico.desktop.ui

import java.io.File
import javax.swing.JFileChooser
import javax.swing.JOptionPane
import javax.swing.UIManager
import javax.swing.filechooser.FileNameExtensionFilter

/** Native-looking Swing file choosers (called on the AWT event thread, which Compose clicks run on). */
object Dialogs {
    private var lastDir: File? = null

    fun initLookAndFeel() {
        try {
            UIManager.setLookAndFeel(UIManager.getSystemLookAndFeelClassName())
        } catch (_: Exception) {
        }
    }

    private fun chooser(title: String, dir: File?): JFileChooser = JFileChooser(dir ?: lastDir).apply {
        dialogTitle = title
        isAcceptAllFileFilterUsed = true
    }

    fun chooseFolder(title: String = "选择文件夹", dir: File? = null): File? {
        val c = chooser(title, dir)
        c.fileSelectionMode = JFileChooser.DIRECTORIES_ONLY
        return if (c.showOpenDialog(null) == JFileChooser.APPROVE_OPTION) c.selectedFile?.also { lastDir = it.parentFile } else null
    }

    fun openFile(title: String, filterName: String, extensions: List<String>, dir: File? = null): File? {
        val c = chooser(title, dir)
        val f = FileNameExtensionFilter(filterName, *extensions.toTypedArray())
        c.addChoosableFileFilter(f)
        c.fileFilter = f
        return if (c.showOpenDialog(null) == JFileChooser.APPROVE_OPTION) c.selectedFile?.also { lastDir = it.parentFile } else null
    }

    fun saveFile(title: String, defaultName: String, dir: File? = null): File? {
        val c = chooser(title, dir)
        c.selectedFile = File(dir ?: lastDir ?: File(System.getProperty("user.home")), defaultName)
        if (c.showSaveDialog(null) != JFileChooser.APPROVE_OPTION) return null
        val f = c.selectedFile ?: return null
        lastDir = f.parentFile
        if (f.exists()) {
            val r = JOptionPane.showConfirmDialog(null, "「${f.name}」已存在，要覆盖吗？", "确认覆盖", JOptionPane.YES_NO_OPTION)
            if (r != JOptionPane.YES_OPTION) return null
        }
        return f
    }

    val imageExtensions = listOf("jpg", "jpeg", "png", "webp", "bmp", "gif")
}
