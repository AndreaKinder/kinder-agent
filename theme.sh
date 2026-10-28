#!/usr/bin/env bash
# ==============================================================================
# kinder-agent: Configuración visual y paleta de colores para la terminal
# ==============================================================================

# Reseteo y modificadores
COLOR_RESET="\033[0m"
COLOR_BOLD="\033[1m"
COLOR_DIM="\033[2m"
COLOR_ITALIC="\033[3m"
COLOR_UNDERLINE="\033[4m"

# Paleta temática de la interfaz (admite variables de entorno de Kinder o defaults)
COLOR_USER="${KINDER_THEME_USER:-\033[38;5;75m}"            # Azul suave
COLOR_ASSISTANT="${KINDER_THEME_ASSISTANT:-\033[38;5;150m}" # Verde salvia
COLOR_SYSTEM="${KINDER_THEME_SYSTEM:-\033[38;5;216m}"       # Melocotón / Coral
COLOR_ERROR="${KINDER_THEME_ERROR:-\033[38;5;203m}"         # Rojo suave
COLOR_BORDER="${KINDER_THEME_BORDER:-\033[38;5;240m}"       # Gris sutil
