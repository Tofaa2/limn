#define GLFW_INCLUDE_NONE
#include <GLFW/glfw3.h>

void *glfwGetCocoaWindow(GLFWwindow *window);
void *glfwGetWin32Window(GLFWwindow *window);
void *glfwGetX11Display(void);
unsigned long glfwGetX11Window(GLFWwindow *window);
void *glfwGetWaylandDisplay(void);
void *glfwGetWaylandWindow(GLFWwindow *window);
void *GetModuleHandleW(const unsigned short *name);
