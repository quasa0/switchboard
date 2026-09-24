const copyButton = document.querySelector("[data-copy]");
if (copyButton && navigator.clipboard && window.isSecureContext) {
  copyButton.hidden = false;
  let reset;
  copyButton.addEventListener("click", async () => {
    const status = document.getElementById("copy-status");
    try {
      await navigator.clipboard.writeText(
        document.getElementById(copyButton.dataset.copy).textContent.trim(),
      );
      copyButton.textContent = "Copied ✓";
      status.textContent = "Prompt copied. Paste it into your coding agent.";
      clearTimeout(reset);
      reset = setTimeout(() => {
        copyButton.textContent = "Copy prompt";
      }, 2500);
    } catch {
      status.textContent =
        "Clipboard access was blocked. Select and copy the prompt above.";
    }
  });
}
