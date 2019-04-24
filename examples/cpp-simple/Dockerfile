# Copyright 2017 Google LLC All Rights Reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

FROM gcc:8 as builder

WORKDIR /project

COPY ./sdks/cpp sdk
COPY ./examples/cpp-simple cpp-simple

ADD https://cmake.org/files/v3.14/cmake-3.14.1-Linux-x86_64.sh /cmake-3.14.1-Linux-x86_64.sh
RUN mkdir /opt/cmake
RUN sh /cmake-3.14.1-Linux-x86_64.sh --prefix=/opt/cmake --skip-license
RUN ln -s /opt/cmake/bin/cmake /usr/local/bin/cmake
RUN cmake --version

RUN cd sdk && mkdir -p .build && \
    cd .build && \
    cmake .. -DCMAKE_BUILD_TYPE=Release -G "Unix Makefiles" -Wno-dev && \
    cmake --build .

RUN cd cpp-simple && mkdir -p .build && \
    cd .build && \
    cmake .. -G "Unix Makefiles" -DCMAKE_BUILD_TYPE=Release && \
    cmake --build .

FROM debian:stretch
RUN useradd -m server

COPY --from=builder /project/cpp-simple/.build/server-static /home/server/server
COPY ./bin/server-static /home/server/server-static
RUN chown -R server /home/server && \
    chmod o+x /home/server/server-static

USER server
ENTRYPOINT /home/server/server-static