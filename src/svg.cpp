#include <lunasvg.h>

#include <cstdlib>
#include <cstring>
#include <vector>

extern "C" {

struct SvgPng {
    unsigned char* data;
    size_t length;
};

bool svg_render_png(const char* data, size_t length, unsigned width, unsigned height, SvgPng* output)
{
    auto document = lunasvg::Document::loadFromData(data, length);
    if(document == nullptr)
        return false;

    auto bitmap = document->renderToBitmap(width, height);
    if(bitmap.isNull())
        return false;

    std::vector<unsigned char> png;
    if(!bitmap.writeToPng([](void* closure, void* bytes, int size) {
        auto output = static_cast<std::vector<unsigned char>*>(closure);
        auto start = static_cast<unsigned char*>(bytes);
        output->insert(output->end(), start, start + size);
    }, &png))
        return false;

    output->data = static_cast<unsigned char*>(std::malloc(png.size()));
    if(output->data == nullptr)
        return false;

    std::memcpy(output->data, png.data(), png.size());
    output->length = png.size();
    return true;
}

void svg_png_free(unsigned char* data)
{
    std::free(data);
}

}
