/**
 * Mobile navigation toggle for Doxygen documentation
 */

(function () {
  // Only run on mobile devices
  const isMobile = () => window.innerWidth <= 767;

  const initMobileNav = () => {
    if (!isMobile()) return;

    const pageNav = document.getElementById("page-nav");
    if (!pageNav) return;

    // Create toggle button
    const toggleBtn = document.createElement("button");
    toggleBtn.id = "page-nav-toggle";
    toggleBtn.setAttribute("aria-label", "Toggle page navigation");
    // Create hamburger menu spans using safe DOM methods
    for (let i = 0; i < 3; i++) {
      toggleBtn.appendChild(document.createElement("span"));
    }
    document.body.appendChild(toggleBtn);

    // Create backdrop
    const backdrop = document.createElement("div");
    backdrop.id = "page-nav-backdrop";
    document.body.appendChild(backdrop);

    // Toggle function
    const toggleNav = () => {
      const isOpen = pageNav.classList.toggle("mobile-open");
      backdrop.classList.toggle("active", isOpen);
      document.body.style.overflow = isOpen ? "hidden" : "";
    };

    // Event listeners
    toggleBtn.addEventListener("click", toggleNav);
    backdrop.addEventListener("click", toggleNav);

    // Close on escape key
    document.addEventListener("keydown", (e) => {
      if (e.key === "Escape" && pageNav.classList.contains("mobile-open")) {
        toggleNav();
      }
    });
  };

  // Initialize on load and resize
  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", initMobileNav);
  } else {
    initMobileNav();
  }

  window.addEventListener("resize", function () {
    const pageNav = document.getElementById("page-nav");
    const backdrop = document.getElementById("page-nav-backdrop");

    if (!isMobile() && pageNav) {
      pageNav.classList.remove("mobile-open");
      if (backdrop) backdrop.classList.remove("active");
      document.body.style.overflow = "";
    }
  });
})();
