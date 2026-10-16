Video

https://youtu.be/ONd0yVtNpmU

Requisitos
Zig 0.16.0
En Linux o WSL, las librerías gráficas del sistema:
bash
sudo apt install libgl1-mesa-dev libx11-dev libxrandr-dev libxinerama-dev libxi-dev libxcursor-dev
Cómo correrlo

Desde la carpeta del proyecto:

bash
zig build run

La primera vez Zig descarga y compila Raylib, así que tarda unos minutos.

Controles
Tecla	Acción
A / D, flechas o arrastrar con el mouse	Rotar el diorama
W / S	Inclinar la cámara
Rueda del mouse o Q / E	Acercar y alejar la cámara
Espacio	Rotación automática
P	Animar las olas del agua
B	Activar o quitar el haz de luz del faro
G	Muestras de iluminación indirecta (0, 1, 2 o 4)
M	Resolución automática o fija en media
C	Guardar una captura (captura.png)
R	Grabar los cuadros de una vuelta completa en video_frames/
H	Mostrar u ocultar la ayuda

Cuando la cámara se queda quieta, la imagen se va limpiando sola en unos segundos.